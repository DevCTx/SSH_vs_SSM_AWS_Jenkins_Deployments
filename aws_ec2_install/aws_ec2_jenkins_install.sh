#!/bin/bash
#
# Create an EC2 instance that will host Jenkins:
#   - grant an admin SSH access 
#   - and a potential IAM role accorded to the chosen registry/transport options
#      --registry dockerhub --transport ssh -> no IAM role needed at all.
#      --registry  ecr   -> $ECR_FULL_ROLE      (aws ecr get-login-password from Jenkins)
#      --transport ssm   -> $SSM_INSTANCE_ROLE  (aws ssm send-command from Jenkins)
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
echo "=== Creation of a Jenkins EC2 instance with registry=${REGISTRY} and transport=${TRANSPORT}) ==="

# Get and prepare the AMI + volume size
aws_get_ami_info

# Prepare the script to install Docker + Compose + Buildx 
aws_prepare_install_docker_script

####################################################################################################
# Admin SSH access: Lets the operator connect to the Jenkins host and run jenkins_aws_install.sh 
# always created, regardless of the deployment transport (SSH/SSM) used later by the pipelines
####################################################################################################
JENKINS_EC2_NAME=jenkins-ec2
JENKINS_EC2_KEY=jenkins-ec2-key     # SSH KEY for connecting local to JENKINS-EC2
JENKINS_EC2_SG=jenkins-ec2-sg       # Security group for JENKINS-EC2 Instance 

# Create a SSH Key to let local connect to the Jenkins-EC2
aws_create_SSH_key "${JENKINS_EC2_KEY}"

# Security group + rules for ports TCP 22 and 8080 opened
set_env JENKINS_EC2_SG_ID "$(aws_create_sg $JENKINS_EC2_SG)"
aws_open_ingress_port $JENKINS_EC2_SG_ID "22" "$(get_local_public_ipV4)/32"   # For local script to connect
aws_open_ingress_port $JENKINS_EC2_SG_ID "8080" "0.0.0.0/0"   # For Jenkins UI AND github webhook


####################################################################################################
# IAM role for AWS API calls made BY Jenkins (ECR push, SSM send-command).
# Skipped entirely for the dockerhub+ssh combo, which needs no AWS API access.
####################################################################################################
NEEDS_PROFILE=false
JENKINS_EC2_ROLE="jenkins-ec2-role"
JENKINS_EC2_PROFILE="jenkins-ec2-profile"
 
if [ "${TRANSPORT}" = "ssm" ]; then
  aws_prepare_role_and_profile "${JENKINS_EC2_ROLE}" "${JENKINS_EC2_PROFILE}" "${SSM_INSTANCE_ROLE}"
  NEEDS_PROFILE=true
fi
 
if [ "${REGISTRY}" = "ecr" ]; then
  aws_prepare_role_and_profile "${JENKINS_EC2_ROLE}" "${JENKINS_EC2_PROFILE}" "${ECR_FULL_ROLE}"
  NEEDS_PROFILE=true
fi

####################################################################################################
# Creates an AWS Linux 2023 Instance and installs Docker (user-data)
# and launch it with both the admin SSH key and the IAM instance profile (if needed)
####################################################################################################
if [ "${NEEDS_PROFILE}" = true ]; then
  set_env JENKINS_EC2_ID "$(aws_create_instance "t3.small" "${JENKINS_EC2_NAME}" "${JENKINS_EC2_SG_ID}" "${JENKINS_EC2_KEY}" "${JENKINS_EC2_PROFILE}")"
else
  set_env JENKINS_EC2_ID "$(aws_create_instance "t3.small" "${JENKINS_EC2_NAME}" "${JENKINS_EC2_SG_ID}" "${JENKINS_EC2_KEY}")"
fi

# 4. Get the public IP address and set it into .env file
set_env JENKINS_EC2_IP "$(aws_get_public_instance_ip "${JENKINS_EC2_ID}")"


echo ""
echo "=================================================="
echo "  ${JENKINS_EC2_NAME} instance created : ${JENKINS_EC2_ID}"
echo "  Public IP : ${JENKINS_EC2_IP}   (saved as JENKINS_EC2_IP in ${ENV_FILE})"
echo "  SSH key : $(dirname "$0")/$JENKINS_EC2_KEY.pem"
echo "  Test access : ssh -i $(dirname "$0")/$JENKINS_EC2_KEY.pem ec2-user@${JENKINS_EC2_IP}"
if [ "${TRANSPORT}" = "ssm" ]; then
  echo "  SSM enabled  : may take 30-60s to be activated on first boot"
  echo "  Test access  : aws ssm send-command --instance-ids ${JENKINS_EC2_ID} \\"
  echo "                   --document-name \"AWS-RunShellScript\" --parameters commands=\"echo ok\")"
fi
echo "=================================================="
echo ""
