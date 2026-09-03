#!/bin/bash
#
# aws_ec2_app_uninstall.sh
# Terminates the app EC2 instance for ONE combo and removes its
# combo-scoped IAM role/profile. Undoes exactly what
# aws_ec2_app_install.sh created for that combo -- never more.
#
# NOT removed (shared with sibling combos, left alone on purpose):
#   - app-ec2-<transport>-sg  (shared by both registries on that transport)
#   - app-ec2-ssh-key         (shared by both ssh combos)
#   - the ECR repository      (shared by ecr+ssh and ecr+ssm)
#
# Usage: ./aws_ec2_app_uninstall.sh <dockerhub|ecr> <ssh|ssm>
#
set -e
cd "$(dirname "$0")"    # Runs the script into this folder

source ../env_install/env_shared_library.sh
source ./aws_shared_library.sh

REGISTRY="$1"
TRANSPORT="$2"

if [ "${REGISTRY}" != "dockerhub" ] && [ "${REGISTRY}" != "ecr" ] \
|| [ "${TRANSPORT}" != "ssh" ] && [ "${TRANSPORT}" != "ssm" ]; then
  echo "Use: $0 <dockerhub|ecr> <ssh|ssm>"
  exit 1
fi

COMBO_SUFFIX="$(echo "${REGISTRY}_${TRANSPORT}" | tr '[:lower:]' '[:upper:]')"
APP_EC2_ID="$(eval echo \$"APP_EC2_ID_${COMBO_SUFFIX}")"
APP_EC2_ROLE="app-ec2-${REGISTRY}-${TRANSPORT}-role"
APP_EC2_PROFILE="app-ec2-${REGISTRY}-${TRANSPORT}-profile"

echo ""
echo "=== Uninstalling the app EC2 instance for ${REGISTRY}/${TRANSPORT} ==="

if [ -n "${APP_EC2_ID}" ]; then
  echo "Terminating instance ${APP_EC2_ID}..."
  aws ec2 terminate-instances --instance-ids "${APP_EC2_ID}" >/dev/null
  aws ec2 wait instance-terminated --instance-ids "${APP_EC2_ID}"
else
  echo "No APP_EC2_ID_${COMBO_SUFFIX} in .env — nothing to terminate."
fi

# Role/profile are combo-scoped (never shared), safe to remove unconditionally.
if aws iam get-instance-profile --instance-profile-name "${APP_EC2_PROFILE}" >/dev/null 2>&1; then
  echo "Removing IAM profile/role ${APP_EC2_PROFILE}/${APP_EC2_ROLE}..."
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "${APP_EC2_PROFILE}" --role-name "${APP_EC2_ROLE}" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "${APP_EC2_PROFILE}" 2>/dev/null || true
  for policy_arn in $(aws iam list-attached-role-policies --role-name "${APP_EC2_ROLE}" \
                        --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "${APP_EC2_ROLE}" --policy-arn "${policy_arn}"
  done
  aws iam delete-role --role-name "${APP_EC2_ROLE}" 2>/dev/null || true
else
  echo "No IAM profile ${APP_EC2_PROFILE} — nothing to remove."
fi

# Clear this combo's .env entries only.
sed -i "/^APP_EC2_ID_${COMBO_SUFFIX}=/d;/^APP_EC2_IP_${COMBO_SUFFIX}=/d" "${ENV_FILE}"

echo ""
echo "Left untouched on purpose (may still be used by a sibling combo):"
echo "  - security group app-ec2-${TRANSPORT}-sg"
[ "${TRANSPORT}" = "ssh" ] && echo "  - SSH key app-ec2-ssh-key"
[ "${REGISTRY}" = "ecr" ] && echo "  - the ECR repository (demo-java-app) and ECR_REGISTRY in .env"
echo ""
echo "✅ ${REGISTRY}/${TRANSPORT} app instance uninstalled."
echo ""