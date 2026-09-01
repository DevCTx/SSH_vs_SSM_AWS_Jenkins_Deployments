#!/bin/bash
#
# env_shared_library.sh : Shared library for ENVIRONMENT VARIABLES functions
# Use it through another script : source ./env_shared_library.sh
#

# ENV_FILE always points at the repo root .env, no matter which script
# (jenkins_install/, aws_ec2_install/, ...) sources this library.
_ENV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${_ENV_LIB_DIR}/../.env"
touch "${ENV_FILE}"
set -a
source "${ENV_FILE}"
set +a


################################################################################
# Get an IMDSv2 token (empty string if not on AWS / IMDS disabled)
# use TOKEN=$(get_imds_token)
################################################################################
get_imds_token() {
    curl -s --max-time 1 -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60"
}

################################################################################
# Get the public IPv4 via AWS IMDS (requires a valid token)
# use MY_IPV4=$(get_aws_public_ipV4 "$token")
################################################################################
get_aws_public_ipV4() {
    local token="$1"
    curl -s -f --max-time 1 -H "X-aws-ec2-metadata-token: ${token}" \
        http://169.254.169.254/latest/meta-data/public-ipv4
}

################################################################################
# Get the public IPv4 via an external service (non-AWS fallback)
# use MY_IPV4=$(get_external_public_ipV4)
################################################################################
get_local_public_ipV4() {
    curl -s -4 --max-time 5 ifconfig.me
}

################################################################################
# UPDATE AN ENVIRONMENT VARIABLE
# use : set_env <env_var> <value>
################################################################################
set_env() {
  local env_var="$1"
  local value="$2"  

  #echo "" >&2
  #echo "Set ${env_var} at ${value} into it into ${ENV_FILE} file" >&2

  grep -v "^${env_var}=" "${ENV_FILE}" 2>/dev/null > "${ENV_FILE}.tmp" || true
  echo "${env_var}=${value}" >> "${ENV_FILE}.tmp"
  mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"

  export "${env_var}=${value}"
}

####################################################
# REMOVE VARIABLES FROM .env
# use : unset_env <env_var>
####################################################
unset_env() {
  local env_var="$1"

  #echo "" >&2
  #echo "Unset ${env_var} from ${ENV_FILE} file" >&2

  [ -f "${ENV_FILE}" ] || return 0
  grep -v "^${env_var}=" "${ENV_FILE}" > "${ENV_FILE}.tmp" || true
  mv -f "${ENV_FILE}.tmp" "${ENV_FILE}"

  unset "${env_var}"
}