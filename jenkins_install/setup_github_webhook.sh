#!/bin/bash
#
# setup_github_webhook.sh
# Creates or updates the GitHub webhook pointing at this Jenkins instance.
# The Jenkins URL is resolved automatically, no interactive prompt, so this
# script can be re-run unattended (needed every time the Cloudflare tunnel
# restarts with a new URL):
#   running on AWS   -> direct public IP (JENKINS_INGRESS_IP)
#   running locally  -> always through a Cloudflare tunnel (creating a public IP)
#
set -e
cd "$(dirname "$0")"    # Runs the script into this folder


####################################################################################################
# 1. Set the Environment Variables
# Source .env : GITHUB_OWNER, GITHUB_JENKINS_TOKEN, REPO
####################################################################################################

source ../env_install/env_shared_library.sh     # Use the ENV shared functions
: "${GITHUB_JENKINS_TOKEN:?Set GITHUB_JENKINS_TOKEN in .env first}"
: "${REPO:?Set REPO=<owner>/<repo> in .env first}"

API="https://api.github.com/repos/$REPO/hooks"
AUTH=(-H "Authorization: Bearer $GITHUB_JENKINS_TOKEN" -H "Accept: application/vnd.github+json")


####################################################################################################
# 2. Resolve the Jenkins URL by detecting where this script currently runs:
#   on AWS   -> direct public IP (JENKINS_INGRESS_IP)
#   locally  -> always through a Cloudflare tunnel (no public IP to rely on)
####################################################################################################

command -v curl >/dev/null || { echo "Install curl: sudo apt install -y curl"; exit 1; }

if TOKEN=$(get_imds_token) && [ -n "${TOKEN}" ]; then
  : "${JENKINS_INGRESS_IP:?Set JENKINS_INGRESS_IP in .env first}"
  JENKINS_URL="http://${JENKINS_INGRESS_IP}:8080"
  echo ""
  echo "Running on AWS — Use the direct Jenkins URL : ${JENKINS_URL}"
else
  echo ""
  echo "Running locally — Ensure a Cloudflare tunnel (URL changes on every restart)"
  source ../cloudflare/setup_cloudflare_tunnel.sh
  JENKINS_URL="${JENKINS_TUNNEL_URL}"
fi

HOOK_URL="$JENKINS_URL/github-webhook/"


####################################################################################################
# 3. Find the hook (by /jenkins-webhook/), create if absent, else update -> idempotent
####################################################################################################

github_api() {
  local method="$1"
  local url="$2"
  local body="${3:-}"
 
  # curl -w appends the HTTP status code after a newline, so it can be
  # split apart from the JSON body once the call returns.
  local response
  if [ -n "$body" ]; then
    response=$(curl -s -w $'\n%{http_code}' -X "$method" "${AUTH[@]}" "$url" -d "$body")
  else
    response=$(curl -s -w $'\n%{http_code}' -X "$method" "${AUTH[@]}" "$url")
  fi
 
  # Display the error if exists
  local status_code="${response##*$'\n'}"
  local json_body="${response%$'\n'*}"
 
  if [[ "$status_code" == 2* ]]; then
    printf '%s' "$json_body"
    return 0
  fi
 
  local error_message
  error_message=$(printf '%s' "$json_body" | jq -r '.message // .' 2>/dev/null)
  echo "ERROR ${status_code} — GitHub says: ${error_message}" >&2
  exit 1
}

command -v jq >/dev/null || { echo "Install jq: sudo apt install -y jq"; exit 1; }

HOOK_ID=$(github_api GET "$API" \
  | jq -r '.[] | select(.config.url | test("github-webhook")) | .id' | head -1)

BODY=$(jq -n --arg url "$HOOK_URL" \
  '{name:"web", config:{url:$url, content_type:"json"}, events:["push"], active:true}')

if [ -n "$HOOK_ID" ]; then
  github_api PATCH "$API/$HOOK_ID" "$BODY" >/dev/null
  echo ""
  echo "✅ Webhook UPDATED (id $HOOK_ID) -> $HOOK_URL"
else
  github_api POST "$API" "$BODY" >/dev/null
  echo ""
  echo "✅ Webhook CREATED -> $HOOK_URL"
fi

# just for convenience
set_env JENKINS_URL "$JENKINS_URL"