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
else
  : "${ECR_REGISTRY:?Set ECR_REGISTRY in .env first}"
fi


####################################################################################################
# Recreate if needed the app EC2 instance for these parameters 
# so the SSH key / IAM profile will match REGISTRY/TRANSPORT
####################################################################################################
if [ "${APP_EC2_REGISTRY:-}" = "${REGISTRY}" ] && [ "${APP_EC2_TRANSPORT:-}" = "${TRANSPORT}" ]; then
  echo "=== App EC2 instance already set up for ${REGISTRY}/${TRANSPORT} ==="
else
  echo "=== Preparing the app EC2 instance for ${REGISTRY}/${TRANSPORT} ==="
  ./aws_ec2_install/aws_ec2_app_install.sh "${REGISTRY}" "${TRANSPORT}"
 
  # Re-read .env: the install script above just wrote a fresh APP_EC2_IP/APP_EC2_ID
  source ./env_install/env_shared_library.sh
fi
 
if [ "${TRANSPORT}" = "ssh" ]; then
  : "${APP_EC2_IP:?aws_ec2_app_install.sh did not set APP_EC2_IP}"
else
  : "${APP_EC2_ID:?aws_ec2_app_install.sh did not set APP_EC2_ID}"
fi


####################################################################################################
# Load the matching pipeline config BEFORE triggering the webhook
####################################################################################################
if [ "${REGISTRY}" = "dockerhub" ] && [ "${TRANSPORT}" = "ssh" ]; then
  CONFIG_NAME="any-dockerhub-ssh"
elif [ -n "${JENKINS_EC2_ID:-}" ]; then
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
    curl -s "https://hub.docker.com/v2/repositories/${DOCKER_USERNAME}/${APP_IMAGE_NAME}/tags?page_size=1&ordering=last_updated" \
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
# Verify EC2 is running that exact tag.
####################################################################################################
echo ""
echo "=== Verifying the deployed tag on EC2 (up to 2 min) ==="
echo "Check on Jenkins for current status. Still waiting..."
 
check_running_image() {
  if [ "${TRANSPORT}" = "ssh" ]; then
    ssh -o StrictHostKeyChecking=no -i ./aws_ec2_install/app-ec2-key.pem \
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