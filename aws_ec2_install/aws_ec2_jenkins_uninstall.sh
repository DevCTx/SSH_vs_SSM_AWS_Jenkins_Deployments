#!/bin/bash
#
# aws_ec2_jenkins_uninstall.sh
# Terminates the Jenkins-on-AWS instance and removes everything
# aws_ec2_jenkins_install.sh created for it. Unlike the app instances,
# nothing here is shared with another combo, so everything is removed.
#
# Usage: ./aws_ec2_jenkins_uninstall.sh
#
set -e
cd "$(dirname "$0")"    # Runs the script into this folder

source ../env_install/env_shared_library.sh

JENKINS_EC2_ROLE="jenkins-ec2-role"
JENKINS_EC2_PROFILE="jenkins-ec2-profile"
JENKINS_EC2_SG="jenkins-ec2-sg"
JENKINS_EC2_KEY="jenkins-ec2-ssh-key"

echo ""
echo "=== Uninstalling the Jenkins-on-AWS instance ==="

if [ -n "${JENKINS_EC2_ID:-}" ]; then
  echo "Terminating instance ${JENKINS_EC2_ID}..."
  aws ec2 terminate-instances --instance-ids "${JENKINS_EC2_ID}" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "${JENKINS_EC2_ID}"
else
  echo "No JENKINS_EC2_ID in .env — nothing to terminate."
fi

if aws iam get-instance-profile --instance-profile-name "${JENKINS_EC2_PROFILE}" >/dev/null 2>&1; then
  echo "Removing IAM profile/role ${JENKINS_EC2_PROFILE}/${JENKINS_EC2_ROLE}..."
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "${JENKINS_EC2_PROFILE}" --role-name "${JENKINS_EC2_ROLE}" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "${JENKINS_EC2_PROFILE}" 2>/dev/null || true
  for policy_arn in $(aws iam list-attached-role-policies --role-name "${JENKINS_EC2_ROLE}" \
                        --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "${JENKINS_EC2_ROLE}" --policy-arn "${policy_arn}"
  done
  aws iam delete-role --role-name "${JENKINS_EC2_ROLE}" 2>/dev/null || true
fi

if [ -n "${JENKINS_EC2_SG_ID:-}" ]; then
  echo "Waiting for the instance's network interface to detach before deleting the security group..."
  sleep 10
  aws ec2 delete-security-group --group-id "${JENKINS_EC2_SG_ID}" 2>/dev/null || \
    echo "⚠️  Could not delete ${JENKINS_EC2_SG_ID} yet — retry manually in a minute if needed."
fi

echo "Deleting SSH key pair ${JENKINS_EC2_KEY}..."
aws ec2 delete-key-pair --key-name "${JENKINS_EC2_KEY}" 2>/dev/null || true
rm -f "${JENKINS_EC2_KEY}.pem"

sed -i '/^JENKINS_EC2_ID=/d;/^JENKINS_EC2_IP=/d;/^JENKINS_EC2_SG_ID=/d' "${ENV_FILE}"

echo ""
echo "✅ Jenkins-on-AWS instance uninstalled."
echo ""