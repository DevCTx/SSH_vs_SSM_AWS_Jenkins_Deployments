#!/bin/bash
#
# reload_jenkins_config.sh
# Reloads the desired Jenkins' JCasC configuration. 
# jenkins-config.yaml is mounted as a volume (see docker-compose.yaml)
#
# Usage:
#   ./reload_jenkins_config.sh                    # reload the current jenkins-config.yaml as-is
#   ./reload_jenkins_config.sh <config-name>.yaml # switch to <config-name>.yaml first, then reload
#     e.g. ./reload_jenkins_config.sh local-ecr-ssh.yaml

set -e
cd "$(dirname "$0")"    # Runs the script into this folder

source ../env_install/env_shared_library.sh

CONFIG_NAME="${1:-}"

####################################################################################################
# Switch to a different config if specified
####################################################################################################
if [ -n "${CONFIG_NAME}" ]; then
  SOURCE_FILE="${CONFIG_NAME}"
  [ -f "${SOURCE_FILE}" ] || { echo "Unknown config: ${SOURCE_FILE} not found"; exit 1; }
  cp "${SOURCE_FILE}" ../jenkins_install/controller/jenkins-config.yaml
  echo "Switched to ${SOURCE_FILE}"
fi

[ -f ../jenkins_install/controller/jenkins-config.yaml ] || {
  echo "../jenkins_install/controller/jenkins-config.yaml not found"
  echo "use:  $0 <config-name>.yaml"
  exit 1
}

####################################################################################################
# Trigger the JCasC hot reload via the Jenkins REST API.
####################################################################################################
JENKINS_URL="http://${JENKINS_INGRESS_IP}:8080"
AUTH=(-u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}")

echo ""
echo "=== Reloading JCasC configuration ==="
CRUMB=$(curl -s "${AUTH[@]}" \
  "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")

curl -s "${AUTH[@]}" -H "${CRUMB}" -X POST "${JENKINS_URL}/configuration-as-code/reload"

echo ""
echo "✅ Configuration reloaded."