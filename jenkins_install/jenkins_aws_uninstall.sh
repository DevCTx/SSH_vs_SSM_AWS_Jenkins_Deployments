#!/bin/bash
#
# jenkins_aws_uninstall.sh
# Mirrors jenkins_aws_install.sh: uninstalls the Jenkins stack ON the AWS
# instance, then terminates that instance too (via aws_ec2_jenkins_uninstall.sh).
# One command undoes what one command created.
#
# Usage:
#   ./jenkins_aws_uninstall.sh            # keep the jenkins_home volume before terminating
#   ./jenkins_aws_uninstall.sh --purge    # also delete the volume (jobs, history) first
#
set -e
cd "$(dirname "$0")"    # Runs the script into this folder

source ../env_install/env_shared_library.sh
: "${JENKINS_EC2_IP:?No JENKINS_EC2_IP in .env — is Jenkins even installed on AWS?}"

JENKINS_EC2_KEY="../aws_ec2_install/jenkins-ec2-ssh-key.pem"
REMOTE_HOME="/home/ec2-user/jenkins-ci-cd"
SSH_OPTS=(-o StrictHostKeyChecking=no -i "${JENKINS_EC2_KEY}")

echo ""
echo "=== Uninstalling Jenkins on ${JENKINS_EC2_IP} ==="

PURGE_FLAG=""
[ "${1:-}" = "--purge" ] && PURGE_FLAG="--purge"

ssh "${SSH_OPTS[@]}" "ec2-user@${JENKINS_EC2_IP}" \
  "${REMOTE_HOME}/jenkins_install/jenkins_local_uninstall.sh ${PURGE_FLAG}"

sed -i '/^JENKINS_INGRESS_IP=/d;/^JENKINS_URL=/d;/^JENKINS_ADMIN_USER=/d;/^JENKINS_ADMIN_PASSWORD=/d;/^JENKINS_TARGET=/d' "${ENV_FILE}"

# Software uninstalled -- now terminate the instance itself too.
../aws_ec2_install/aws_ec2_jenkins_uninstall.sh

echo ""
echo "✅ Jenkins fully uninstalled from AWS (instance terminated)."
echo ""