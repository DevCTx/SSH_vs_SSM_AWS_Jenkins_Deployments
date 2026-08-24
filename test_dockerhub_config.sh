#!/bin/bash
#
# test_dockerhub_config.sh
#
# Use: ./test_dockerhub_config.sh

set -e
cd "$(dirname "$0")"    # Runs the script into this folder

source ./env_install/env_shared_library.sh
: "${DOCKER_USERNAME:?Set DOCKER_USERNAME in .env first}"
: "${DOCKERHUB_PAT:?Set DOCKERHUB_PAT in .env first}"

command -v docker >/dev/null || { echo "Install docker first"; exit 1; }

if echo "${DOCKERHUB_PAT}" | docker login -u "${DOCKER_USERNAME}" --password-stdin >/dev/null 2>&1; then
  echo "✅ Login Succeeded (${DOCKER_USERNAME})"
else
  echo "❌ Login failed — check DOCKER_USERNAME/DOCKERHUB_PAT in .env"
  exit 1
fi

docker logout >/dev/null 2>&1 || true
