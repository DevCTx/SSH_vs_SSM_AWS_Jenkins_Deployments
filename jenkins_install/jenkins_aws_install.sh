#!/bin/bash
#
# jenkins_aws_install.sh
# - Transfers env_install/, jenkins_install/, jenkins_configs/ and .env
#   to the EC2 instance created by aws_ec2_install/aws_ec2_jenkins_install.sh
# - then runs jenkins_local_install.sh remotely.
#
# Use: ./jenkins_aws_install.sh

set -e
cd "$(dirname "$0")"    # Runs the script into this folder

source ../env_install/env_shared_library.sh
: "${JENKINS_EC2_IP:?Run aws_ec2_install/aws_ec2_jenkins_install.sh first}"
: "${JENKINS_EC2_ID:?Run aws_ec2_install/aws_ec2_jenkins_install.sh first}"

# Internal use only (this script already cd'd into jenkins_install/).
JENKINS_EC2_KEY="../aws_ec2_install/jenkins-ec2-ssh-key.pem"
APP_EC2_KEY="../aws_ec2_install/app-ec2-ssh-key.pem"
REMOTE_HOME="/home/ec2-user/jenkins-ci-cd"
SSH_OPTS=(-o StrictHostKeyChecking=no -i "${JENKINS_EC2_KEY}")

echo ""
echo "=== Preparing remote folders on ${JENKINS_EC2_IP} ==="
ssh "${SSH_OPTS[@]}" "ec2-user@${JENKINS_EC2_IP}" \
  "mkdir -p ${REMOTE_HOME}/env_install ${REMOTE_HOME}/aws_ec2_install ${REMOTE_HOME}/jenkins_install ${REMOTE_HOME}/jenkins_configs"

echo ""
echo "=== Transferring env_install/, jenkins_install/, jenkins_configs/ and .env ==="
scp -r "${SSH_OPTS[@]}" ../env_install/. \
  "ec2-user@${JENKINS_EC2_IP}:${REMOTE_HOME}/env_install/"
scp -r "${SSH_OPTS[@]}" . \
  "ec2-user@${JENKINS_EC2_IP}:${REMOTE_HOME}/jenkins_install/"
scp -r "${SSH_OPTS[@]}" ../jenkins_configs/. \
  "ec2-user@${JENKINS_EC2_IP}:${REMOTE_HOME}/jenkins_configs/"
scp "${SSH_OPTS[@]}" "${ENV_FILE}" \
  "ec2-user@${JENKINS_EC2_IP}:${REMOTE_HOME}/.env"

# The ssh key only exists once an ssh combo's app instance has been
# created locally. If not yet, test_deployments.sh transfers it itself
# the first time an ssh combo is actually tested.
if [ -f "${APP_EC2_KEY}" ]; then
  echo ""
  echo "=== Transferring the app deployment SSH key ==="
  scp "${SSH_OPTS[@]}" "${APP_EC2_KEY}" \
    "ec2-user@${JENKINS_EC2_IP}:${REMOTE_HOME}/aws_ec2_install/"
fi

echo ""
echo "=== Running jenkins_local_install.sh remotely ==="
ssh -t "${SSH_OPTS[@]}" "ec2-user@${JENKINS_EC2_IP}" \
  "${REMOTE_HOME}/jenkins_install/jenkins_local_install.sh"

# Jenkins runs on AWS, so the operator reaches it through its public IP
set_env JENKINS_INGRESS_IP "${JENKINS_EC2_IP}"

echo ""
echo "=== Retrieving the admin credentials generated remotely ==="
scp "${SSH_OPTS[@]}" "ec2-user@${JENKINS_EC2_IP}:${REMOTE_HOME}/.env" /tmp/remote.env
for var in JENKINS_ADMIN_USER JENKINS_ADMIN_PASSWORD; do
  value=$(grep "^$var=" /tmp/remote.env | cut -d= -f2-)
  [ -n "${value}" ] && set_env "$var" "$value"
done
rm -f /tmp/remote.env

echo ""
echo "=================================================="
echo "  Jenkins ready on AWS : http://${JENKINS_INGRESS_IP}:8080"
echo "  Login : ${JENKINS_ADMIN_USER} / ${JENKINS_ADMIN_PASSWORD}"
echo "=================================================="
echo ""