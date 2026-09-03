#!/bin/bash
#
# jenkins_local_install.sh
# Installs the Jenkins core stack (controller + agents, no pipelines yet)
# and sets up the GitHub webhook. Combo-agnostic -- registry/transport are
# only picked later, at test_deployments.sh time.
#
# Locally, no public IP exists for the webhook, so a Cloudflare tunnel is
# created automatically (see setup_github_webhook.sh).
#
# Usage: ./jenkins_local_install.sh

set -e
cd "$(dirname "$0")"    # Runs the script into this folder

source ../env_install/env_shared_library.sh
: "${GITHUB_JENKINS_TOKEN:?Set GITHUB_JENKINS_TOKEN in .env first}"
: "${GITHUB_OWNER:?Set GITHUB_OWNER in .env first}"
: "${REPO:?Set REPO in .env first}"

echo ""
echo "=== Installing Jenkins locally ==="
 
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
# PREREQUISITES: install Docker + Compose + Buildx if missing (needs root).
# On AWS, user-data already installs Docker in the background -- installing
# it again here would race with that process over the same files. Just wait
# for it instead.
####################################################################################################
if TOKEN=$(get_imds_token) && [ -n "${TOKEN}" ]; then
  echo "Waiting for Docker (installed by user-data) to be ready..."
  for i in $(seq 1 60); do
    command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1 \
      && sudo docker compose version >/dev/null 2>&1 && break
    sleep 5
  done
else
  command -v docker >/dev/null || {
    echo ""
    echo "Docker is not installed — installing it needs root privileges,"
    echo "you'll be asked for your sudo password once for this step."
    sudo bash <<'INSTALL_DOCKER' >/dev/null
set -e
if [ -f /etc/debian_version ]; then
  apt-get update -qq
  apt-get install -qq -y ca-certificates curl gnupg

  # docker.io is often outdated and lacks the Compose v2/Buildx plugins.
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
 
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo ${UBUNTU_CODENAME}) stable" \
    > /etc/apt/sources.list.d/docker.list
 
  apt-get update -qq
  apt-get install -qq -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
else
  # AL2023 has its own docker package -- no repo needed. Compose/Buildx
  # ship as separate plugin binaries.
  yum install -y -q docker
  mkdir -p /usr/local/lib/docker/cli-plugins
  curl -fsSL --max-time 60 https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
    -o /usr/local/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  BUILDX_VERSION="v0.35.0"
  curl -fsSL --max-time 60 "https://github.com/docker/buildx/releases/download/${BUILDX_VERSION}/buildx-${BUILDX_VERSION}.linux-amd64" \
    -o /usr/local/lib/docker/cli-plugins/docker-buildx
  chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx
fi
systemctl enable --now docker
INSTALL_DOCKER
  }
fi

set_env DOCKER_GID "$(stat -c '%g' /var/run/docker.sock)"
set_env JENKINS_INGRESS_IP "$(hostname -I | awk '{print $1}')"

####################################################################################################
# Build agents. --env-file ../.env: sudo drops DOCKER_GID, so Compose needs it explicitly.
####################################################################################################

# base-agent first: the others are built FROM it.
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
# Reset to a neutral default (auth on, no combo job) every install.
####################################################################################################
cp ../jenkins_configs/default.yaml controller/jenkins-config.yaml
[ -f ../aws_ec2_install/app-ec2-ssh-key.pem ] || touch ../aws_ec2_install/app-ec2-ssh-key.pem


# Start the controller -- reload_jenkins_config.sh loads a real combo later.
sudo docker compose --env-file ../.env up -d --build controller
echo "Waiting 15s for the Jenkins controller to start..."
sleep 15

# Update GitHub webhook with a token
export TOKEN
./setup_github_webhook.sh

echo ""
if [ -n "${TOKEN}" ]; then
  set_env JENKINS_TARGET "aws"
  echo "Jenkins controller started on this instance."
else
  set_env JENKINS_TARGET "local"
  echo "=================================================="
  echo "  Jenkins ready locally : http://${JENKINS_INGRESS_IP}:8080"
  echo "  Login : ${JENKINS_ADMIN_USER} / ${JENKINS_ADMIN_PASSWORD}"
  echo "=================================================="
fi
unset TOKEN
echo ""