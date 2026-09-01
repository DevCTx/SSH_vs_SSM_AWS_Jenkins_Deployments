#!/bin/bash
#
# aws_ec2_app_install.sh
# Creates the EC2 instance that will run the deployed app.
#
# One persistent, idempotent instance PER COMBO (app-ec2-<registry>-<transport>).
# Each combo gets its own instance, security group, and IAM role -- no port
# 22 leaks onto SSM combos, and the IP no longer changes on every destroy/recreate.
#
# Usage: ./aws_ec2_app_install.sh <dockerhub|ecr> <ssh|ssm>
#
set -e
cd "$(dirname "$0")"    # Runs the script into this folder

source ../env_install/env_shared_library.sh     # Use the ENV shared functions
source ./aws_shared_library.sh     # Use the AWS shared functions

REGISTRY="$1"
TRANSPORT="$2"

if [ "${REGISTRY}" != "dockerhub" ] && [ "${REGISTRY}" != "ecr" ] \
|| [ "${TRANSPORT}" != "ssh" ] && [ "${TRANSPORT}" != "ssm" ]; then
  echo "Use: $0 <dockerhub|ecr> <ssh|ssm>"
  exit 1
fi

echo ""
echo "=== Preparing the app EC2 instance for ${REGISTRY}/${TRANSPORT} ==="

# Get and prepare the AMI + volume size
aws_get_ami_info

# Prepare the script to install Docker + Compose + Buildx
aws_prepare_install_docker_script

####################################################################################################
# Shared per TRANSPORT, not per combo: SG rules and the SSH key only depend
# on the transport (open port 22 or not) -- the registry has no bearing on
# either, so both registries reuse the same SG/key for a given transport.
####################################################################################################
APP_EC2_NAME="app-ec2-${REGISTRY}-${TRANSPORT}"
APP_EC2_SG="app-ec2-${TRANSPORT}-sg"

# Security group: port 80 always opened (the app must stay reachable),
set_env APP_EC2_SG_ID "$(aws_create_sg "${APP_EC2_SG}")"
aws_open_ingress_port "${APP_EC2_SG_ID}" "80" "0.0.0.0/0"   # public access to the deployed app

# port 22 opened only for the ssh transport, on THIS combo's own security
# group -- never on the ssm combos', which stay port-22-free.
if [ "${TRANSPORT}" = "ssh" ]; then
  APP_EC2_SSH_KEY="app-ec2-ssh-key"
  aws_create_SSH_key "${APP_EC2_SSH_KEY}"

  # port 22 always opend to local IP for debugging if needed 
  LOCAL_IP="$(get_local_public_ipV4)"
  aws_open_ingress_port "${APP_EC2_SG_ID}" "22" "${LOCAL_IP}/32"
  
  # and open to Jenkins'IP if it is different of local IP (Jenkins installed on AWS)
  if [ -n "${JENKINS_EC2_IP:-}" ] && [ "${JENKINS_EC2_IP}" != "${LOCAL_IP}" ]; then
    aws_open_ingress_port "${APP_EC2_SG_ID}" "22" "${JENKINS_EC2_IP}/32"
  fi
fi


####################################################################################################
# IAM role for AWS API calls made ON the app instance (SSM agent, ECR pull).
# Skipped entirely for the dockerhub+ssh combo, which needs no AWS API access.
####################################################################################################
APP_EC2_ROLE="app-ec2-${REGISTRY}-${TRANSPORT}-role"
APP_EC2_PROFILE="app-ec2-${REGISTRY}-${TRANSPORT}-profile"

APP_EC2_SSH_KEY_ARG=""
APP_EC2_PROFILE_ARG=""

# Define the --key-name argument for the instance creation
if [ "${TRANSPORT}" = "ssh" ]; then
  APP_EC2_SSH_KEY_ARG="${APP_EC2_SSH_KEY}"
fi

# Define the --iam-instance-profile argument for the instance creation
if [ "${TRANSPORT}" = "ssm" ]; then
  aws_prepare_role_and_profile "${APP_EC2_ROLE}" "${APP_EC2_PROFILE}" "${SSM_INSTANCE_ROLE}"
  APP_EC2_PROFILE_ARG="${APP_EC2_PROFILE}"
fi
# combinable
if [ "${REGISTRY}" = "ecr" ]; then
  aws_prepare_ecr_registry
  aws_prepare_role_and_profile "${APP_EC2_ROLE}" "${APP_EC2_PROFILE}" "${ECR_PULL_ROLE}"
  APP_EC2_PROFILE_ARG="${APP_EC2_PROFILE}"
fi

####################################################################################################
# Creates an AWS Linux 2023 Instance and installs Docker (user-data), or
# just confirms it's already there and running -- aws_create_instance is
# idempotent, so calling this script again for the same combo is a no-op.
####################################################################################################

INSTANCE_ID="$(aws_create_instance "t3.micro" "${APP_EC2_NAME}" "${APP_EC2_SG_ID}" "${APP_EC2_SSH_KEY_ARG}" "${APP_EC2_PROFILE_ARG}")"
PUBLIC_IP="$(aws_get_public_instance_ip "${INSTANCE_ID}")"

# Combo-specific keys (e.g. APP_EC2_ID_DOCKERHUB_SSH, APP_EC2_IP_ECR_SSM) so
# all 4 combos' instances coexist in .env without overwriting each other. 
COMBO_SUFFIX="$(echo "${REGISTRY}_${TRANSPORT}" | tr '[:lower:]' '[:upper:]')"
set_env "APP_EC2_ID_${COMBO_SUFFIX}" "${INSTANCE_ID}"
set_env "APP_EC2_IP_${COMBO_SUFFIX}" "${PUBLIC_IP}"

echo ""
echo "=================================================="
echo "  ${APP_EC2_NAME} instance ready : ${INSTANCE_ID}"
echo "  Public IP : ${PUBLIC_IP}   (saved as APP_EC2_IP_${COMBO_SUFFIX} in ${ENV_FILE})"
echo "  App URL   : http://${PUBLIC_IP}"
if [ "${TRANSPORT}" = "ssh" ]; then
  echo "  SSH key : $(dirname "$0")/${APP_EC2_SSH_KEY}.pem"
  echo "  Test access : ssh -i $(dirname "$0")/${APP_EC2_SSH_KEY}.pem ec2-user@${PUBLIC_IP}"
else
  echo "  SSM enabled  : may take 30-60s to be activated on first boot"
  echo "  Test access  : aws ssm send-command --instance-ids ${INSTANCE_ID} \\"
  echo "                   --document-name \"AWS-RunShellScript\" --parameters commands=\"echo ok\""
fi
echo "=================================================="
echo ""