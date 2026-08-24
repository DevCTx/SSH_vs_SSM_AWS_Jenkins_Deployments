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
 
# Cookie jar shared between the two calls: with basic auth alone (no
# session persisted), Jenkins may issue the crumb for one implicit session
# and reject it on the next request as belonging to a different one.
COOKIE_JAR=$(mktemp)
 
CRUMB=$(curl -s -c "${COOKIE_JAR}" "${AUTH[@]}" \
  "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
 
STATUS=$(curl -s -o /tmp/reload_response.html -w '%{http_code}' \
  -b "${COOKIE_JAR}" "${AUTH[@]}" -H "${CRUMB}" -X POST "${JENKINS_URL}/configuration-as-code/reload")
 
rm -f "${COOKIE_JAR}"
 
if [[ "${STATUS}" != 2* ]] && [[ "${STATUS}" != 3* ]]; then
  echo "❌ Reload failed (HTTP ${STATUS})"
  cat /tmp/reload_response.html
  rm -f /tmp/reload_response.html
  exit 1
fi
rm -f /tmp/reload_response.html
 
echo "✅ Configuration reloaded."

####################################################################################################
# Delete any OTHER combo job 
####################################################################################################
ALL_JOBS=(dockerhub-ssh-ec2 dockerhub-ssm-ec2 ecr-ssh-ec2 ecr-ssm-ec2)
 
case "${CONFIG_NAME}" in
  *dockerhub*ssh*) ACTIVE_JOB=dockerhub-ssh-ec2 ;;
  *dockerhub*ssm*) ACTIVE_JOB=dockerhub-ssm-ec2 ;;
  *ecr*ssh*)       ACTIVE_JOB=ecr-ssh-ec2 ;;
  *ecr*ssm*)       ACTIVE_JOB=ecr-ssm-ec2 ;;
  *)               ACTIVE_JOB="" ;;
esac
 
if [ -n "${ACTIVE_JOB}" ]; then
  CRUMB=$(curl -s "${AUTH[@]}" \
    "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
 
  for job in "${ALL_JOBS[@]}"; do
    [ "${job}" = "${ACTIVE_JOB}" ] && continue
    curl -s -o /dev/null "${AUTH[@]}" -H "${CRUMB}" -X POST "${JENKINS_URL}/job/${job}/doDelete" || true
  done
  echo "✅ Only ${ACTIVE_JOB} remains active."
fi