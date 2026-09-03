#!/bin/bash
#
# test_deployments.sh
# End-to-end smoke test: triggers a pipeline run (empty commit + push), waits
# for a new image tag to appear on the registry, then verifies the EC2
# instance is actually running that exact tag.
#
# Use: ./test_deployments.sh <dockerhub|ecr> <ssh|ssm>

set -e
cd "$(dirname "$0")"    # Runs the script into this folder

REGISTRY="$1"
TRANSPORT="$2"
if [ "${REGISTRY}" != "dockerhub" ] && [ "${REGISTRY}" != "ecr" ] \
|| [ "${TRANSPORT}" != "ssh" ] && [ "${TRANSPORT}" != "ssm" ]; then
  echo "Use: $0 <dockerhub|ecr> <ssh|ssm>"
  exit 1
fi

source ./env_install/env_shared_library.sh

# Must match APP_IMAGE_NAME / APP_CONTAINER_NAME in pipelines/*/Jenkinsfile
APP_IMAGE_NAME="demo-java-app"
APP_CONTAINER_NAME="java-app"

if [ "${REGISTRY}" = "dockerhub" ]; then
  : "${DOCKER_USERNAME:?Set DOCKER_USERNAME in .env first}"
fi


####################################################################################################
# ECR/SSM combos need AWS CLI creds -- create a local IAM user for them the
# first time such a combo is tested, if Jenkins isn't on AWS already (where
# the instance's own IAM role covers it instead -- see aws_ec2_jenkins_install.sh).
####################################################################################################
if [ "${JENKINS_TARGET:-local}" = "local" ] && { [ "${REGISTRY}" = "ecr" ] || [ "${TRANSPORT}" = "ssm" ]; }; then
  source ./aws_ec2_install/aws_shared_library.sh
  aws_prepare_local_jenkins_credentials
fi


####################################################################################################
# Create or Recreate if needed the app EC2 instance for these parameters 
# so the SSH key / IAM profile will match REGISTRY/TRANSPORT. One persistent instance per combo.
####################################################################################################
./aws_ec2_install/aws_ec2_app_install.sh "${REGISTRY}" "${TRANSPORT}"
 
# Re-read .env in case aws_ec2_app_install.sh just created this combo's instance
source ./env_install/env_shared_library.sh
 
COMBO_SUFFIX="$(echo "${REGISTRY}_${TRANSPORT}" | tr '[:lower:]' '[:upper:]')"
if [ "${TRANSPORT}" = "ssh" ]; then
  APP_EC2_IP="$(eval echo \$"APP_EC2_IP_${COMBO_SUFFIX}")"
  : "${APP_EC2_IP:?APP_EC2_IP_${COMBO_SUFFIX} not set in .env}"
else
  APP_EC2_ID="$(eval echo \$"APP_EC2_ID_${COMBO_SUFFIX}")"
  : "${APP_EC2_ID:?APP_EC2_ID_${COMBO_SUFFIX} not set in .env}"
fi


####################################################################################################
# Refresh the Jenkins controller: it only reads .env at creation, not on a
# JCasC reload. Check JENKINS_TARGET (where Jenkins runs), not
# get_imds_token (this script itself always runs locally).
####################################################################################################
if [ "${JENKINS_TARGET:-local}" = "local" ]; then
  echo "=== Refreshing the local Jenkins controller so it picks up any new instance details ==="
  (cd jenkins_install && sudo docker compose --env-file ../.env up -d controller)

  echo "Waiting for Jenkins to finish restarting..."
  for i in $(seq 1 24); do
    STATUS=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' "http://${JENKINS_INGRESS_IP}:8080/login" 2>/dev/null || echo "000")
    [ "${STATUS}" = "200" ] && break
    sleep 5
  done
else
  echo "=== Refreshing the Jenkins controller on AWS so it picks up any new instance details ==="
  JENKINS_EC2_KEY="aws_ec2_install/jenkins-ec2-ssh-key.pem"
  REMOTE_HOME="/home/ec2-user/jenkins-ci-cd"
  SSH_OPTS=(-o StrictHostKeyChecking=no -i "${JENKINS_EC2_KEY}")

  # Merge combo keys only -- keeps machine-specific values (DOCKER_GID...) intact.
  ENV_TMP="/tmp/.env.tmp"
  scp "${SSH_OPTS[@]}" "ec2-user@${JENKINS_EC2_IP}:${REMOTE_HOME}/.env" "${ENV_TMP}"
  grep -vE '^(APP_EC2_|ECR_REGISTRY=)' "${ENV_TMP}" > "${ENV_TMP}.new"
  grep -E '^(APP_EC2_|ECR_REGISTRY=)' "${ENV_FILE}" >> "${ENV_TMP}.new"
  scp "${SSH_OPTS[@]}" "${ENV_TMP}.new" "ec2-user@${JENKINS_EC2_IP}:${REMOTE_HOME}/.env"
  rm -f "${ENV_TMP}" "${ENV_TMP}.new"

  # ssh transport: also push the app key remotely (cheap to repeat).
  if [ "${TRANSPORT}" = "ssh" ]; then
    scp "${SSH_OPTS[@]}" aws_ec2_install/app-ec2-ssh-key.pem \
      "ec2-user@${JENKINS_EC2_IP}:${REMOTE_HOME}/aws_ec2_install/"
  fi

  ssh "${SSH_OPTS[@]}" "ec2-user@${JENKINS_EC2_IP}" \
    "cd ${REMOTE_HOME}/jenkins_install && sudo docker compose --env-file ../.env up -d controller"

  echo "Waiting for Jenkins to finish restarting..."
  for i in $(seq 1 24); do
    STATUS=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' "http://${JENKINS_EC2_IP}:8080/login" 2>/dev/null || echo "000")
    [ "${STATUS}" = "200" ] && break
    sleep 5
  done
fi


####################################################################################################
# Load the matching pipeline config BEFORE triggering the webhook
####################################################################################################
if [ "${REGISTRY}" = "dockerhub" ] && [ "${TRANSPORT}" = "ssh" ]; then
  CONFIG_NAME="any-dockerhub-ssh"
elif [ "${JENKINS_TARGET:-local}" = "aws" ]; then
  CONFIG_NAME="aws-${REGISTRY}-${TRANSPORT}"
else
  CONFIG_NAME="local-${REGISTRY}-${TRANSPORT}"
fi
 
echo "=== Loading config: ${CONFIG_NAME}.yaml ==="
./jenkins_configs/reload_jenkins_config.sh "${CONFIG_NAME}.yaml"


####################################################################################################
# Get the lastest tag pushed on ECR or DockerHub
####################################################################################################
get_latest_tag() {
  if [ "${REGISTRY}" = "dockerhub" ]; then
    curl -s --max-time 15 "https://hub.docker.com/v2/repositories/${DOCKER_USERNAME}/${APP_IMAGE_NAME}/tags?page_size=1&ordering=last_updated" \
      | jq -r '.results[0].name // empty'
  else
    aws ecr describe-images --repository-name "${APP_IMAGE_NAME}" \
      --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageTags[0]' \
      --output text 2>/dev/null || echo ""
  fi
}

echo "=== Checking the current tag before triggering the pipeline ==="
BEFORE_TAG=$(get_latest_tag)
echo "Current tag: ${BEFORE_TAG:-<none>}"


####################################################################################################
# Trigger the pipeline with an empty commit — no code change needed.
####################################################################################################
echo ""
echo "=== Triggering the pipeline (empty commit + push) ==="
git commit --allow-empty -m "test: trigger deployment ($(date -u +%FT%TZ))"
git push


####################################################################################################
# Wait for a new tag to appear on the registry (5 min timeout).
####################################################################################################
echo ""
echo "=== Waiting for the new image on ${REGISTRY} (up to 5 min) ==="
echo "Check on Jenkins for current status. Still waiting..."
AFTER_TAG=""
for i in $(seq 1 30); do
  sleep 10
  AFTER_TAG=$(get_latest_tag)
  if [ -n "${AFTER_TAG}" ] && [ "${AFTER_TAG}" != "${BEFORE_TAG}" ]; then
    echo "✅ New tag published: ${AFTER_TAG}"
    break
  fi
done
 
if [ -z "${AFTER_TAG}" ] || [ "${AFTER_TAG}" = "${BEFORE_TAG}" ]; then
  echo "❌ No new tag appeared after 5 minutes — check the Jenkins build"
  exit 1
fi


####################################################################################################
# Verify that EC2 is running that exact tag.
####################################################################################################
echo ""
echo "=== Verifying the deployed tag on EC2 (up to 2 min) ==="
echo "Check on Jenkins for current status. Still waiting..."
 
check_running_image() {
  if [ "${TRANSPORT}" = "ssh" ]; then
    ssh -o StrictHostKeyChecking=no -i ./aws_ec2_install/app-ec2-ssh-key.pem \
      "ec2-user@${APP_EC2_IP}" \
      "docker ps --filter name=${APP_CONTAINER_NAME} --format '{{.Image}}'"
  else
    local cmd_id
    cmd_id=$(aws ssm send-command \
      --instance-ids "${APP_EC2_ID}" \
      --document-name "AWS-RunShellScript" \
      --parameters "commands=[\"docker ps --filter name=${APP_CONTAINER_NAME} --format '{{.Image}}'\"]" \
      --query 'Command.CommandId' --output text)
    aws ssm wait command-executed --instance-id "${APP_EC2_ID}" --command-id "${cmd_id}"
    aws ssm get-command-invocation \
      --instance-id "${APP_EC2_ID}" --command-id "${cmd_id}" \
      --query 'StandardOutputContent' --output text | tr -d '\n'
  fi
}

RUNNING_IMAGE=""
for i in $(seq 1 12); do
  RUNNING_IMAGE=$(check_running_image)
  if [[ "${RUNNING_IMAGE}" == *":${AFTER_TAG}" ]]; then
    break
  fi
  sleep 10
done
 
echo "Running image on EC2: ${RUNNING_IMAGE}"
 
if [[ "${RUNNING_IMAGE}" == *":${AFTER_TAG}" ]]; then
  echo "✅ EC2 is running the latest tag (${AFTER_TAG})"
else
  echo "❌ EC2 is NOT running the latest tag after 2 minutes (expected ...:${AFTER_TAG}, got '${RUNNING_IMAGE}')"
  exit 1
fi