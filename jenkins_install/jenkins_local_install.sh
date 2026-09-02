#!/bin/bash
#
# jenkins_local_install.sh
# Installs the Jenkins core stack locally via Docker Compose 
# (controller + agents, no pipelines yet)
#
# Next, run configs/ and pipelines/ scripts.
#
# A local machine has no reliable public IP for the GitHub webhook, so 
# a Cloudflare tunnel is automatically created for that.
# (see setup_github_webhook.sh)
#
# Usage: ./jenkins_local_install.sh <dockerhub|ecr> <ssh|ssm>

set -e
cd "$(dirname "$0")"    # Runs the script into this folder

REGISTRY="$1"
TRANSPORT="$2"
if [ "${REGISTRY}" != "dockerhub" ] && [ "${REGISTRY}" != "ecr" ] \
|| [ "${TRANSPORT}" != "ssh" ] && [ "${TRANSPORT}" != "ssm" ]; then
  echo "Use: $0 <dockerhub|ecr> <ssh|ssm>"
  exit 1
fi

source ../env_install/env_shared_library.sh
: "${GITHUB_JENKINS_TOKEN:?Set GITHUB_JENKINS_TOKEN in .env first}"
: "${GITHUB_OWNER:?Set GITHUB_OWNER in .env first}"
: "${REPO:?Set REPO in .env first}"

if [ "${REGISTRY}" = "dockerhub" ]; then
  : "${DOCKER_USERNAME:?Set DOCKER_USERNAME in .env first}"
  : "${DOCKERHUB_PAT:?Set DOCKERHUB_PAT in .env first}"
fi

echo ""
echo "=== Installing Jenkins locally (registry=${REGISTRY}, transport=${TRANSPORT}) ==="
 
####################################################################################################
# Jenkins admin credentials: asked once, then reused on every re-run.
####################################################################################################
if ! grep -q "^JENKINS_ADMIN_USER=" "${ENV_FILE}" 2>/dev/null; then
  read -p "Define a Jenkins admin username: " ADMIN_USER
  set_env JENKINS_ADMIN_USER "${ADMIN_USER}"
fi

if ! grep -q "^JENKINS_ADMIN_PASSWORD=" "${ENV_FILE}" 2>/dev/null; then
  ADMIN_PASSWORD=$(openssl rand -base64 24)
  set_env JENKINS_ADMIN_PASSWORD "${ADMIN_PASSWORD}"
  echo "Generated Jenkins admin password: ${ADMIN_PASSWORD}"
fi

####################################################################################################
# ECR/SSM combos need AWS CLI creds -- create a local IAM user for them if Jenkins isn't on AWS already.
####################################################################################################
if [ "${REGISTRY}" = "ecr" ] || [ "${TRANSPORT}" = "ssm" ]; then
  if ! TOKEN=$(get_imds_token) || [ -z "${TOKEN}" ]; then
    source ../aws_ec2_install/aws_shared_library.sh
    aws_prepare_local_jenkins_credentials
  fi
fi

####################################################################################################
# PREREQUISITES : Verify Docker, Compose and Buildx on the host 
# Set as block to be able to run it as root privilege (needed for docker.pgp and docker daemon)
####################################################################################################
command -v docker >/dev/null || {
  echo ""
  echo "Docker is not installed — installing it needs root privileges,"
  echo "you'll be asked for your sudo password once for this step."
  sudo bash <<'INSTALL_DOCKER'
set -e
if [ -f /etc/debian_version ]; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg
 
  # Download the docker key to let the system accept to add a new docker repository source
  # because the standard Ubuntu/Debian package (docker.io) is often outdated and does not 
  # reliably include the Compose v2/Buildx plugins that the script requires, 
  # unlike the official Docker repository.
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
 
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo ${UBUNTU_CODENAME}) stable" \
    > /etc/apt/sources.list.d/docker.list
 
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  # Contrary to Debian/Ubuntu, AL2023 maintains its own docker package at a reasonably up-to-date version
  yum install -y yum-utils
  yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
INSTALL_DOCKER
}

set_env DOCKER_GID "$(stat -c '%g' /var/run/docker.sock)"
set_env JENKINS_INGRESS_IP "$(hostname -I | awk '{print $1}')"

####################################################################################################
# Build agents. A single docker-capable agent handles every combo. --env-file ../.env: sudo drops DOCKER_GID, so Compose is told where to find it.
####################################################################################################

# separated to be sure that the build of base-agent finishs 
# before the start of the others who depend of it
sudo docker compose --env-file ../.env build base-agent
sudo docker compose --env-file ../.env build maven-agent
sudo docker compose --env-file ../.env build docker-aws-agent


####################################################################################################
# Test agent images
####################################################################################################

test_agent () {
  echo ""
  echo "=== Testing $1 ==="
  sudo docker run --rm --entrypoint bash "${@:3}" "$1" -c "$2"
}

test_agent jenkins-base-agent  "java -version && git --version"
test_agent jenkins-maven-agent "java -version && mvn -v"
test_agent jenkins-docker-aws-agent "docker --version && aws --version" -v /var/run/docker.sock:/var/run/docker.sock

####################################################################################################
# ensure that the two files mounted as volumes already exist as actual files (even if empty)
####################################################################################################
[ -f controller/jenkins-config.yaml ] || touch controller/jenkins-config.yaml
[ -f ../aws_ec2_install/app-ec2-ssh-key.pem ] || touch ../aws_ec2_install/app-ec2-ssh-key.pem

####################################################################################################
# Start the controller and run jenkins-config.yaml at the first boot
# Jenkins has any pipeline — this script only brings up the empty core.
# The configuration jenkins-config.yaml needs to be copied from a desired configs/*.yaml before
####################################################################################################
sudo docker compose --env-file ../.env up -d --build controller
echo "Waiting 15s for the Jenkins controller to start..."
sleep 15

echo ""
if TOKEN=$(get_imds_token) && [ -n "${TOKEN}" ]; then
  # Running on AWS: this is the remote step of jenkins_aws_install.sh, which
  # prints its own accurate banner (public IP, correct next steps) once this
  # SSH session ends -- avoid a second, misleading one with the private IP.
  echo "Jenkins controller started on this instance."
else
  echo "=================================================="
  echo "  Jenkins ready locally : http://${JENKINS_INGRESS_IP}:8080"
  echo "  Login : ${JENKINS_ADMIN_USER} / ${JENKINS_ADMIN_PASSWORD}"
  echo ""
  echo "  Next steps:"
  echo "  1. Set the GitHub Webhook (with a Cloudflare tunnel automatically)"
  echo "     ./jenkins_install/setup_github_webhook.sh"
  echo "  2. Run a test deployment for the combo of your choice"
  echo "     ./test_deployments.sh <dockerhub|ecr> <ssh|ssm>"
  echo "=================================================="
fi
echo ""