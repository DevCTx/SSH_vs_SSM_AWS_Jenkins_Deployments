#!/bin/bash
#
# test_deployments.sh
# End-to-end smoke test: triggers a pipeline run (empty commit + push), waits
# for a new image tag to appear on the registry, then verifies the EC2
# instance is actually running that exact tag.
#
# Use: ./test_deployments.sh <dockerhub|ecr> <ssh|ssm>
# Run from the root of your checked-out repo (the git push targets REPO).

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

if [ "${TRANSPORT}" = "ssh" ]; then
  : "${APP_EC2_IP:?Run aws_ec2_install/aws_ec2_app_install.sh first}"
else
  : "${APP_EC2_ID:?Run aws_ec2_install/aws_ec2_app_install.sh first}"
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
# Poll the registry until a new tag appears (5 min timeout).
####################################################################################################
echo ""
echo "=== Waiting for the new image on ${REGISTRY} (up to 5 min) ==="
AFTER_TAG=""
for i in $(seq 1 30); do
  sleep 10
  AFTER_TAG=$(get_latest_tag)
  if [ -n "${AFTER_TAG}" ] && [ "${AFTER_TAG}" != "${BEFORE_TAG}" ]; then
    echo "✅ New tag published: ${AFTER_TAG}"
    break
  fi
  echo "  still waiting... (${i}/30)"
done

if [ -z "${AFTER_TAG}" ] || [ "${AFTER_TAG}" = "${BEFORE_TAG}" ]; then
  echo "❌ No new tag appeared after 5 minutes — check the Jenkins build"
  exit 1
fi

####################################################################################################
# Verify EC2 is running that exact tag.
####################################################################################################
echo ""
echo "=== Verifying the deployed tag on EC2 ==="

if [ "${TRANSPORT}" = "ssh" ]; then
  RUNNING_IMAGE=$(ssh -o StrictHostKeyChecking=no -i ./aws_ec2_install/app-ec2-key.pem \
    "ec2-user@${APP_EC2_IP}" \
    "docker ps --filter name=${APP_CONTAINER_NAME} --format '{{.Image}}'")
else
  CMD_ID=$(aws ssm send-command \
    --instance-ids "${APP_EC2_ID}" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"docker ps --filter name=${APP_CONTAINER_NAME} --format '{{.Image}}'\"]" \
    --query 'Command.CommandId' --output text)
  aws ssm wait command-executed --instance-id "${APP_EC2_ID}" --command-id "${CMD_ID}"
  RUNNING_IMAGE=$(aws ssm get-command-invocation \
    --instance-id "${APP_EC2_ID}" --command-id "${CMD_ID}" \
    --query 'StandardOutputContent' --output text | tr -d '\n')
fi

echo "Running image on EC2: ${RUNNING_IMAGE}"

if [[ "${RUNNING_IMAGE}" == *":${AFTER_TAG}" ]]; then
  echo "✅ EC2 is running the latest tag (${AFTER_TAG})"
else
  echo "❌ EC2 is NOT running the latest tag (expected ...:${AFTER_TAG}, got '${RUNNING_IMAGE}')"
  exit 1
fi