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
# If Jenkins runs on AWS, push the local config file to the remote instance first 
####################################################################################################
if [ "${JENKINS_TARGET:-local}" = "aws" ]; then
  JENKINS_EC2_KEY="../aws_ec2_install/jenkins-ec2-ssh-key.pem"
  REMOTE_HOME="/home/ec2-user/jenkins-ci-cd"
  echo ""
  echo "=== Jenkins runs on AWS: pushing the config file to ${JENKINS_EC2_IP} ==="
  scp -o StrictHostKeyChecking=no -i "${JENKINS_EC2_KEY}" \
    ../jenkins_install/controller/jenkins-config.yaml \
    "ec2-user@${JENKINS_EC2_IP}:${REMOTE_HOME}/jenkins_install/controller/jenkins-config.yaml"
fi


####################################################################################################
# Trigger the JCasC hot reload via the Jenkins REST API.
####################################################################################################
if [ "${JENKINS_TARGET:-local}" = "aws" ]; then
  JENKINS_HOST="${JENKINS_EC2_IP}"
else
  JENKINS_HOST="${LOCAL_INGRESS_IP}"
fi
JENKINS_URL="http://${JENKINS_HOST}:8080"
AUTH=(-u "${JENKINS_ADMIN_USER}:${JENKINS_ADMIN_PASSWORD}")
 
echo ""
echo "=== Reloading JCasC configuration ==="
 
# Cookie jar shared between calls, otherwise the crumb can be rejected.
COOKIE_JAR=$(mktemp)
 
CRUMB=$(curl -s --max-time 15 -c "${COOKIE_JAR}" "${AUTH[@]}" \
  "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
 
STATUS=$(curl -s --max-time 15 -o /tmp/reload_response.html -w '%{http_code}' \
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
  DELETE_COOKIE_JAR=$(mktemp)
  CRUMB=$(curl -s --max-time 15 -c "${DELETE_COOKIE_JAR}" "${AUTH[@]}" \
    "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,%22:%22,//crumb)")
 
  for job in "${ALL_JOBS[@]}"; do
    [ "${job}" = "${ACTIVE_JOB}" ] && continue
    STATUS=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' \
      -b "${DELETE_COOKIE_JAR}" "${AUTH[@]}" -H "${CRUMB}" -X POST "${JENKINS_URL}/job/${job}/doDelete")
    # 404 just means it was already gone -- fine. Anything else worth flagging.
    if [ "${STATUS}" != "200" ] && [ "${STATUS}" != "302" ] && [ "${STATUS}" != "404" ]; then
      echo "⚠️  Could not delete job ${job} (HTTP ${STATUS})"
    fi
  done
  rm -f "${DELETE_COOKIE_JAR}"
  echo "✅ Only ${ACTIVE_JOB} remains active."
fi