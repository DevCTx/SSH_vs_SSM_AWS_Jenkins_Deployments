#!/bin/bash
#
# test_github_config.sh
#
# Use: ./test_github_config.sh

set -e
cd "$(dirname "$0")"    # Runs the script into this folder

source ./env_install/env_shared_library.sh
: "${GITHUB_JENKINS_TOKEN:?Set GITHUB_JENKINS_TOKEN in .env first}"
: "${GITHUB_OWNER:?Set GITHUB_OWNER in .env first}"
: "${REPO:?Set REPO=<owner>/<repo> in .env first}"

AUTH=(-H "Authorization: Bearer $GITHUB_JENKINS_TOKEN")

LOGIN=$(curl -sf "${AUTH[@]}" "https://api.github.com/user" | jq -r '.login')

if [ "${LOGIN}" = "${GITHUB_OWNER}" ]; then
  echo "✅ GITHUB_JENKINS_TOKEN matches GITHUB_OWNER (${LOGIN})"
  curl -sf "${AUTH[@]}" "https://api.github.com/repos/${REPO}" >/dev/null \
    && echo "✅ REPO '${REPO}' is accessible" \
    || { echo "❌ REPO '${REPO}' not found or inaccessible"; exit 1; }
else
  echo "❌ Mismatch: token belongs to '${LOGIN}', not '${GITHUB_OWNER}'"
  exit 1
fi