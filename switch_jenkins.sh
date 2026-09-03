#!/bin/bash
#
# switch_jenkins.sh
# Switches which Jenkins (local or AWS) test_deployments.sh targets, and
# repoints the GitHub webhook at it. Neither instance is reinstalled or
# torn down -- both can stay up at the same time.
#
# Usage: ./switch_jenkins.sh <local|aws>
#
set -e
cd "$(dirname "$0")"

source ./env_install/env_shared_library.sh

TARGET="$1"
if [ "${TARGET}" != "local" ] && [ "${TARGET}" != "aws" ]; then
  echo "Use: $0 <local|aws>"
  exit 1
fi

if [ "${TARGET}" = "aws" ]; then
  : "${JENKINS_EC2_ID:?No AWS Jenkins installed -- run aws_ec2_jenkins_install.sh + jenkins_aws_install.sh first}"
  : "${JENKINS_EC2_IP:?No AWS Jenkins installed -- run aws_ec2_jenkins_install.sh + jenkins_aws_install.sh first}"
fi

set_env JENKINS_TARGET "${TARGET}"

echo ""
echo "=== Repointing the GitHub webhook at the ${TARGET} Jenkins ==="
if [ "${TARGET}" = "aws" ]; then
  ssh -o StrictHostKeyChecking=no -i aws_ec2_install/jenkins-ec2-ssh-key.pem \
    "ec2-user@${JENKINS_EC2_IP}" \
    '/home/ec2-user/jenkins-ci-cd/jenkins_install/setup_github_webhook.sh'
else
  ./jenkins_install/setup_github_webhook.sh
fi

echo ""
echo "✅ Now targeting Jenkins: ${TARGET}"
echo ""