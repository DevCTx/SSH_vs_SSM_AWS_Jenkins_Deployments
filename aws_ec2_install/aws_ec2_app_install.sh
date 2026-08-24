#!/bin/bash
#
# aws_ec2_app_install.sh
# Creates the EC2 instance that will receive the deployed application
# (pulled and run by Jenkins through SSH or SSM, from DockerHub or ECR).
#   --transport ssh -> generates an SSH key pair, opens port 22 to local and Jenkins' IP (if different)
#   --transport ssm -> no SSH key, no port 22 opened; attaches $SSM_INSTANCE_ROLE
#   --registry  ecr -> attaches $ECR_PULL_ROLE (read-only, pull permissions only)
# Port 80 is always opened (the deployed app itself must stay reachable).
# 
# If an instance exists, it will be destroyed first and recreates with the new key/profile parameters
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
echo "=== Creation of an App EC2 instance with registry=${REGISTRY} and transport=${TRANSPORT}) ==="

# Get and prepare the AMI + volume size
aws_get_ami_info

# Prepare the script to install Docker + Compose + Buildx
aws_prepare_install_docker_script

####################################################################################################
# SSH access: only needed when the deployment must be done via SSH. 
# Jenkins uses this key to connect and run "docker pull / docker run" on the app instance.
####################################################################################################
APP_EC2_NAME=app-ec2
APP_EC2_KEY=app-ec2-key    # SSH KEY for Jenkins to connect to APP-EC2 (ssh transport only)
APP_EC2_SG=app-ec2-sg      # Security group for APP-EC2 Instance

EXISTING_ID=$(aws_find_instance_id "${APP_EC2_NAME}")
if [ -n "${EXISTING_ID}" ]; then
  echo "=== Terminating existing instance ${EXISTING_ID} before recreating it ==="
  aws_terminate_instance "${EXISTING_ID}"
fi
 
# Security group: port 80 always opened (the app must stay reachable),
set_env APP_EC2_SG_ID "$(aws_create_sg "${APP_EC2_SG}")"
aws_open_ingress_port "${APP_EC2_SG_ID}" "80" "0.0.0.0/0"   # public access to the deployed app

# port 22 opened only for the ssh transport, 
# restricted to the local IP and Jenkins' own IP (on local or AWS)
if [ "${TRANSPORT}" = "ssh" ]; then
  aws_create_SSH_key "${APP_EC2_KEY}"

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
APP_EC2_ROLE="app-ec2-role"
APP_EC2_PROFILE="app-ec2-profile"
 
APP_EC2_KEY_ARG="" 
APP_EC2_PROFILE_ARG=""  

# Define the --key-name argument for the instance creation
if [ "${TRANSPORT}" = "ssh" ]; then
  APP_EC2_KEY_ARG="${APP_EC2_KEY}"
fi
 
# Define the --iam-instance-profile argument for the instance creation
if [ "${TRANSPORT}" = "ssm" ]; then
  aws_prepare_role_and_profile "${APP_EC2_ROLE}" "${APP_EC2_PROFILE}" "${SSM_INSTANCE_ROLE}"
  APP_EC2_PROFILE_ARG="${APP_EC2_PROFILE}"
fi
# combinable
if [ "${REGISTRY}" = "ecr" ]; then
  aws_prepare_role_and_profile "${APP_EC2_ROLE}" "${APP_EC2_PROFILE}" "${ECR_PULL_ROLE}"
  APP_EC2_PROFILE_ARG="${APP_EC2_PROFILE}"
fi

####################################################################################################
# Creates an AWS Linux 2023 Instance and installs Docker (user-data)
# and launch it with the SSH key (if ssh) and the IAM instance profile (if needed).
# aws_create_instance combines both when both are non-empty.
####################################################################################################
 
set_env APP_EC2_ID "$(aws_create_instance "t3.micro" "${APP_EC2_NAME}" "${APP_EC2_SG_ID}" "${APP_EC2_KEY_ARG}" "${APP_EC2_PROFILE_ARG}")"
 
# Get the public IP address and set it into .env file
set_env APP_EC2_IP "$(aws_get_public_instance_ip "${APP_EC2_ID}")"

# Remember which parameters this instance has used for its configuration
set_env APP_EC2_REGISTRY "${REGISTRY}"
set_env APP_EC2_TRANSPORT "${TRANSPORT}"

echo ""
echo "=================================================="
echo "  ${APP_EC2_NAME} instance created : ${APP_EC2_ID}"
echo "  Public IP : ${APP_EC2_IP}   (saved as APP_EC2_IP in ${ENV_FILE})"
echo "  App URL   : http://${APP_EC2_IP}"
if [ "${TRANSPORT}" = "ssh" ]; then
  echo "  SSH key : $(dirname "$0")/${APP_EC2_KEY}.pem"
  echo "  Test access : ssh -i $(dirname "$0")/${APP_EC2_KEY}.pem ec2-user@${APP_EC2_IP}"
else
  echo "  SSM enabled  : may take 30-60s to be activated on first boot"
  echo "  Test access  : aws ssm send-command --instance-ids ${APP_EC2_ID} \\"
  echo "                   --document-name \"AWS-RunShellScript\" --parameters commands=\"echo ok\" "
fi
echo "=================================================="
echo ""