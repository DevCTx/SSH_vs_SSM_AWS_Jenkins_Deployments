#!/bin/bash
#
# Create an EC2 instance that will host Jenkins:
#   - grant an admin SSH access
#   - and an IAM role covering EVERY combo Jenkins might run, since the
#     combo to test is only chosen later, at test_deployments.sh time:
#       $ECR_FULL_ROLE    (aws ecr get-login-password + cleanup)
#       $SSM_CALLER_ROLE  (aws ssm send-command)
#
# Use: ./aws_ec2_jenkins_install.sh
#
set -e
cd "$(dirname "$0")"    # Runs the script into this folder

source ../env_install/env_shared_library.sh     # Use the ENV shared functions
source ./aws_shared_library.sh     # Use the AWS shared functions
 
echo ""
echo "=== Creation of a Jenkins EC2 instance ==="

# Get and prepare the AMI + volume size
aws_get_ami_info

# Prepare the script to install Docker + Compose + Buildx 
aws_prepare_install_docker_script

####################################################################################################
# Admin SSH access: Lets the operator connect to the Jenkins host and run jenkins_aws_install.sh 
# always created, regardless of the deployment transport (SSH/SSM) used later by the pipelines
####################################################################################################
JENKINS_EC2_NAME=jenkins-ec2
JENKINS_EC2_KEY=jenkins-ec2-ssh-key     # SSH KEY for connecting local to JENKINS-EC2
JENKINS_EC2_SG=jenkins-ec2-sg       # Security group for JENKINS-EC2 Instance 

# Create a SSH Key to let local connect to the Jenkins-EC2
aws_create_SSH_key "${JENKINS_EC2_KEY}"

# Security group + rules for ports TCP 22 and 8080 opened
set_env JENKINS_EC2_SG_ID "$(aws_create_sg $JENKINS_EC2_SG)"
aws_open_ingress_port $JENKINS_EC2_SG_ID "22" "$(get_local_public_ipV4)/32"   # For local script to connect
aws_open_ingress_port $JENKINS_EC2_SG_ID "8080" "0.0.0.0/0"   # For Jenkins UI AND github webhook


####################################################################################################
# IAM role for AWS API calls made BY Jenkins. Always covers both ECR and
# SSM, since the combo is only picked later, at test_deployments.sh time.
####################################################################################################
JENKINS_EC2_ROLE="jenkins-ec2-role"
JENKINS_EC2_PROFILE="jenkins-ec2-profile"
 
aws_prepare_role_and_profile "${JENKINS_EC2_ROLE}" "${JENKINS_EC2_PROFILE}" "${SSM_CALLER_ROLE}"
aws_prepare_role_and_profile "${JENKINS_EC2_ROLE}" "${JENKINS_EC2_PROFILE}" "${ECR_FULL_ROLE}"


####################################################################################################
# Creates an AWS Linux 2023 Instance and installs Docker (user-data)
# and launch it with both the admin SSH key and the IAM instance profile
####################################################################################################
set_env JENKINS_EC2_ID "$(aws_create_instance "t3.small" "${JENKINS_EC2_NAME}" "${JENKINS_EC2_SG_ID}" "${JENKINS_EC2_KEY}" "${JENKINS_EC2_PROFILE}")"
 
# Get the public IP address and set it into .env file
set_env JENKINS_EC2_IP "$(aws_get_public_instance_ip "${JENKINS_EC2_ID}")"


echo ""
echo "=================================================="
echo "  ${JENKINS_EC2_NAME} instance created : ${JENKINS_EC2_ID}"
echo "  Public IP : ${JENKINS_EC2_IP}   (saved as JENKINS_EC2_IP in ${ENV_FILE})"
echo "  SSH key : $(dirname "$0")/$JENKINS_EC2_KEY.pem"
echo "  Test access : ssh -i $(dirname "$0")/$JENKINS_EC2_KEY.pem ec2-user@${JENKINS_EC2_IP}"
echo "  SSM enabled  : may take 30-60s to be activated on first boot"
echo "  Test access  : aws ssm send-command --instance-ids ${JENKINS_EC2_ID} \\"
echo "                   --document-name \"AWS-RunShellScript\" --parameters commands=\"echo ok\""
echo "=================================================="
echo ""