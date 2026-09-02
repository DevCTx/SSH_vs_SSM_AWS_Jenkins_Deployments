#!/bin/bash
#
# aws_shared_library.sh : Shared library for AWS functions (SSH & SSM deployments)
# Use it through another script : source ./aws_shared_library.sh
#

# AWS REGION predefined
REGION=eu-west-3            # Paris

####################################################
# Get and prepare the AMI + volume size
# use : aws_get_ami_info
####################################################
aws_get_ami_info() {

  echo "" >&2
  echo "Get and prepare the AMI + volume size" >&2

  # Get information about the AMI(Amazon Image) because it changes with time and region (ami id)
  AL2023_AMI=$(aws ec2 describe-images --region $REGION --owners amazon \
    --filters "Name=name,Values=al2023-ami-2*-x86_64" \
    --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
 
  # Get the size required by AWS for this image
  IMAGE_SIZE=$(aws ec2 describe-images --region $REGION --image-ids $AL2023_AMI \
    --query 'Images[0].BlockDeviceMappings[0].Ebs.VolumeSize' --output text)
 
  # Ensure enough disk for the app: AMI's required minimum size + 10GB margin (our config)
  VOLUME_SIZE=$(($IMAGE_SIZE + 10))
}


############################################################
# Prepare the script to install Docker + Compose + Buildx 
# on EC2 instance (yum) on first start (via user-data arg)
# use : aws_prepare_install_docker_script
############################################################
aws_prepare_install_docker_script() {
  echo "" >&2
  echo "Prepare the script to install Docker + Compose + Buildx " >&2
  cat > /tmp/install-docker.sh <<'EOF'
#!/bin/bash
yum update -y
yum install -y docker
systemctl enable --now docker
usermod -aG docker ec2-user

# Install Docker Compose v2 and BuildX plugins (not included with yum's docker package)
mkdir -p /usr/local/lib/docker/cli-plugins

curl -fsSL --max-time 60 https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

BUILDX_VERSION="v0.35.0"
curl -SL --max-time 60 "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" \
  -o /usr/local/lib/docker/cli-plugins/docker-buildx
chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
EOF
}


####################################################
# CHECK IF A SSH KEY EXISTS ON LOCAL OR CREATES IT
# use : aws_create_SSH_key <key_name>
####################################################
aws_create_SSH_key() {
  local key_name="$1"

  echo "" >&2 
  echo "Test if Key pair exists for $key_name else (re)create it" >&2

  if [ ! -f "$key_name.pem" ]; then
    aws ec2 delete-key-pair --key-name "$key_name" --region "$REGION" >/dev/null 2>&1  || true
    aws ec2 create-key-pair --key-name "$key_name" --region "$REGION" \
      --query 'KeyMaterial' --output text > "$key_name.pem"
  fi
  
  chmod 400 "$key_name.pem"   # required by AWS
}


####################################################
# DELETE A KEY PAIR (AWS side) + LOCAL .pem
# use : aws_delete_SSH_key <key_name>
####################################################
aws_delete_SSH_key() {
  local key_name="$1"

  echo "" >&2
  echo "Deleting key pair $key_name ..." >&2
  
  aws ec2 delete-key-pair --key-name "$key_name" --region $REGION >/dev/null 2>&1  \
    && echo "Key pair deleted on AWS." >&2 || echo "Key pair absent on AWS." >&2
  
  rm -f "$key_name.pem" && echo "Local $key_name.pem removed."
}



# Policies available for aws_prepare_role_and_profile or aws_delete_role_and_profile.
SSM_INSTANCE_ROLE="arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
ECR_PULL_ROLE="arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
ECR_FULL_ROLE="arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess"  # Needed for delete

# Different from SSM_INSTANCE_ROLE: that one lets an INSTANCE be managed by
# SSM; this one lets a CALLER (Jenkins itself) issue "aws ssm send-command".
SSM_CALLER_ROLE="arn:aws:iam::aws:policy/AmazonSSMFullAccess"

################################################################################
# ENSURE A LOCAL IAM USER + ACCESS KEY EXISTS FOR 'aws-creds'
# use : aws_prepare_local_jenkins_credentials
################################################################################
aws_prepare_local_jenkins_credentials() {
  if [ -n "${JENKINS_AWS_ACCESS_KEY_ID:-}" ] && [ -n "${JENKINS_AWS_SECRET_ACCESS_KEY:-}" ]; then
    echo "JENKINS_AWS_ACCESS_KEY_ID/JENKINS_AWS_SECRET_ACCESS_KEY already set in .env, skipping" >&2
    return 0
  fi

  local user_name="jenkins-local-aws-creds"

  echo "" >&2
  echo "Preparing IAM user ($user_name) for Jenkins-in-local ECR/SSM combos" >&2

  aws iam get-user --user-name "$user_name" >/dev/null 2>&1 || \
    aws iam create-user --user-name "$user_name" >/dev/null

  aws iam attach-user-policy --user-name "$user_name" \
    --policy-arn "$SSM_CALLER_ROLE" >/dev/null 2>&1 || true
  aws iam attach-user-policy --user-name "$user_name" \
    --policy-arn "$ECR_FULL_ROLE" >/dev/null 2>&1 || true

  local key_json
  key_json=$(aws iam create-access-key --user-name "$user_name" --output json)

  set_env JENKINS_AWS_ACCESS_KEY_ID "$(echo "$key_json" | jq -r '.AccessKey.AccessKeyId')"
  set_env JENKINS_AWS_SECRET_ACCESS_KEY "$(echo "$key_json" | jq -r '.AccessKey.SecretAccessKey')"

  echo "Access key created and saved to .env" >&2
}

 
################################################################################
# ENSURE THE ECR REPOSITORY EXISTS AND ECR_REGISTRY IS SET
# use : aws_prepare_ecr_registry
################################################################################
aws_prepare_ecr_registry() {
  if [ -n "${ECR_REGISTRY:-}" ]; then
    echo "ECR_REGISTRY already set in .env, skipping" >&2
    return 0
  fi
 
  local repo_name="demo-java-app"   # must match APP_IMAGE_NAME in pipelines/*/Jenkinsfile
 
  echo "" >&2
  echo "Preparing ECR repository ($repo_name)" >&2
 
  aws ecr describe-repositories --repository-names "$repo_name" --region "$REGION" >/dev/null 2>&1 || \
    aws ecr create-repository --repository-name "$repo_name" --region "$REGION" >/dev/null
 
  local account_id
  account_id=$(aws sts get-caller-identity --query Account --output text)
 
  set_env ECR_REGISTRY "${account_id}.dkr.ecr.${REGION}.amazonaws.com"
}
 

################################################################################
# PREPARE ROLE AND PROFILE FOR INSTANCE
# use : aws_prepare_role_and_profile <role_name> <profile_name> <policy_arn>
################################################################################
aws_prepare_role_and_profile() {
  local role_name="$1"
  local profile_name="$2"
  local policy_arn="$3"

  echo "" >&2
  echo "Create a SSM Role ($role_name) and Profile ($profile_name) for an EC2 instance" >&2

  # The SSM agent is already installed on Amazon Linux 2023 
  # But the instance needs an IAM Role with a SSM policy to use it
  # because only users, groups or roles can have IAM permissions

  cat > /tmp/ec2-assume-role-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

  # Create a role that can be accepted by the EC2 AWS Manager -> Role understanding by EC2
  aws iam get-role --role-name "$role_name" >/dev/null 2>&1 || \
    aws iam create-role --role-name "$role_name" \
      --assume-role-policy-document file:///tmp/ec2-assume-role-policy.json >/dev/null 2>&1 

  # Attach a policy (SSM permissions) to this role -> SSM Role understanding by EC2
  aws iam list-attached-role-policies --role-name "$role_name" \
    --query "AttachedPolicies[?PolicyArn=='${policy_arn}']"  \
    --output text | grep -q . || \
    aws iam attach-role-policy --role-name "$role_name" \
      --policy-arn "${policy_arn}" >/dev/null 2>&1 

  # Create an instance profile to be able to set a role to an specific instance -> EC2 Instance Profile
  aws iam get-instance-profile --instance-profile-name "$profile_name" >/dev/null 2>&1 || \
    aws iam create-instance-profile --instance-profile-name "$profile_name" >/dev/null 2>&1 

  # Attach the SSM role to the Instance Profile -> Acceptable SSM Role for EC2 Instance
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$profile_name" --role-name "$role_name" >/dev/null 2>&1  || true

  sleep 10   # let IAM propagate the instance profile
}


####################################################
# DELETE AN IAM INSTANCE PROFILE + ROLE 
# use : aws_delete_role_and_profile <role_name> <profile_name> <policy_arn>
####################################################
aws_delete_role_and_profile() {
  local role_name="$1"
  local profile_name="$2"
  local policy_arn="$3"

  echo "" >&2
  echo "Delete SSM Role ($role_name) and Profile ($profile_name)" >&2

  # Detach the role from the instance profile first (required before deletion)
  aws iam remove-role-from-instance-profile \
    --instance-profile-name "$profile_name" --role-name "$role_name" >/dev/null 2>&1  || true

  aws iam delete-instance-profile --instance-profile-name "$profile_name" >/dev/null 2>&1  \
    && echo "Instance profile deleted." >&2 || echo "Instance profile absent." >&2

  aws iam detach-role-policy --role-name "$role_name" \
    --policy-arn "${policy_arn}" >/dev/null 2>&1  || true

  aws iam delete-role --role-name "$role_name" >/dev/null 2>&1  \
    && echo "Role deleted." >&2 || echo "Role absent." >&2

  rm -f "/tmp/ec2-assume-role-policy.json"
}



####################################################
# CHECK IF A SECURITY GROUP EXISTS OR CREATE IT
# use : SG=$(aws_create_sg <sg_name>)
####################################################
aws_create_sg() {
  local sg_name="$1"

  echo "" >&2
  echo "Test if $sg_name Security Group exists or create it" >&2

  aws ec2 describe-security-groups --group-names "$sg_name" --region $REGION \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || \
  aws ec2 create-security-group --group-name "$sg_name" \
    --description "$sg_name" --region $REGION --query 'GroupId' --output text
}
 

####################################################
# DELETE A SECURITY GROUP
# use : aws_delete_sg <sg_name>
####################################################
aws_delete_sg() {
  local sg_name="$1"

  echo "" >&2
  echo "Deleting security group $sg_name" >&2

  aws ec2 delete-security-group --group-name "$sg_name" \
    --region $REGION >/dev/null 2>/dev/null \
    && echo "Security group deleted." >&2 \
    || echo "Security group absent or still in use." >&2
}


##################################################################
# AUTHORIZE INGRESS ON <PORT> FROM <CIDR> IN <SECURITY GROUP>
# use : aws_open_ingress_port <sg_id> <port> <cidr>
# if error : answers true
##################################################################
aws_open_ingress_port() {
  local sg_id="$1" 
  local port="$2" 
  local cidr="$3"       

  echo "" >&2
  echo "Authorize ingress on port $port from cidr $cidr in security group $sg_id" >&2

  aws ec2 authorize-security-group-ingress --group-id "$sg_id" \
    --protocol tcp --port "$port" --cidr "$cidr" \
    --region $REGION >/dev/null 2>&1  || true
}


################################################################################
# FIND EXISTING INSTANCE ID BY NAME (running/pending), empty if none
# use : IID=$(aws_find_instance_id <name>)
################################################################################
aws_find_instance_id() {
  local i_name="$1"
  local i_id=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=${i_name}-instance" \
              "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
  [ "$i_id" = "None" ] && i_id=""
  echo "$i_id"
}


################################################################################
# CREATE INSTANCE WITH SSH ACCESS AND/OR SSM INSTANCE PROFILE
# use : IID=$(aws_create_instance <name> <sg_id> <instance_type> [ssh_key_name] [ssm_iam_profile])
################################################################################
aws_create_instance() {
  local instance_type="$1"
  local i_name="$2" 
  local sg_id="$3" 
  local ssh_key_name="${4:-}"       # get or blank
  local ssm_iam_profile="${5:-}"    # get or blank 
 
  # Only Free Tier eligible - t3.small minimum required for Jenkins
  if [ "$instance_type" != "t3.micro" ] \
  && [ "$instance_type" != "t3.small" ] ; then
    echo "Invalid instance_type: '$instance_type' (allowed: t3.micro, t3.small)" >&2
  return 1
  fi

  echo "" >&2
  echo "Tests if the instance $i_name exists or creates it, install docker and wait for running" >&2
 
  # Check if the instance is already created
  local i_id=$(aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=${i_name}-instance" \
              "Name=instance-state-name,Values=running,pending" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
 
  # if not ...
  if [ "$i_id" = "None" ] || [ -z "$i_id" ]; then
    echo "Creating AL2023_AMI ${i_name}-instance (${instance_type} with $VOLUME_SIZE GiB)..." >&2
    
    # define if the instance needs SSH and/or SSM protocol
    # SSH key and IAM profile are independent but combinable 
    # example => Jenkins instance takes a SSH key for admin access
    #            and an IAM profile for AWS API calls
    local protocol_args=()
    if [ -n "$ssh_key_name" ]; then
      protocol_args+=(--key-name "$ssh_key_name")
      echo "SSH key attached: $ssh_key_name" >&2
    fi
    if [ -n "$ssm_iam_profile" ]; then
      protocol_args+=(--iam-instance-profile "Name=$ssm_iam_profile")
      echo "IAM instance profile attached: $ssm_iam_profile" >&2
    fi
    if [ ${#protocol_args[@]} -eq 0 ]; then
      echo "No SSH key and no IAM profile provided" >&2
    fi
 
    # Create the instance with these protocol arguments
    # needs ${protocol_args[@]} to get the full text into parentheses
    # ./tmp/install-docker.sh will be run at the first boot of instance
    i_id=$(aws ec2 run-instances --region $REGION \
      --image-id "$AL2023_AMI" \
      --count 1 \
      --instance-type "$instance_type" \
      --security-group-ids "$sg_id" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${i_name}-instance}]" \
      --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\"}}]" \
      "${protocol_args[@]}" \
      --query 'Instances[0].InstanceId' --output text \
      --user-data file:///tmp/install-docker.sh)  # file:// + /tmp/...
    echo "Instance created: $i_id" >&2
  else
    echo "Instance already exists: $i_id" >&2
  fi
 
  # Wait for the instance to run before to continue
  echo "Waiting for $i_name to be running..." >&2
  aws ec2 wait instance-running --instance-ids "$i_id" --region $REGION
  echo "$i_id"
}


####################################################
# TERMINATE A INSTANCE
# use : aws_terminate_instance <name>
####################################################
aws_terminate_instance() {
  local i_id="$1"

  echo "" >&2
  echo "Terminate $i_id-instance if exists" >&2

  if [ -n "$i_id" ]; then
    aws ec2 terminate-instances --instance-ids $i_id --region $REGION >/dev/null
    echo "Waiting for completion ..." >&2
    aws ec2 wait instance-terminated --instance-ids $i_id --region $REGION
    echo "Instance terminated." >&2
  else
    echo "No instance found." >&2
  fi
}


################################################################################
# GET INSTANCE PUBLIC IP
# use : PUBLIC_IP=$(aws_get_public_instance_ip <instance_id>)
################################################################################
aws_get_public_instance_ip() {
  local instance_id="$1"

  echo "" >&2
  echo "Get the public IP address of $instance_id" >&2

  aws ec2 describe-instances --region $REGION --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}