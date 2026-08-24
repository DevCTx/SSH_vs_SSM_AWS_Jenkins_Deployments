#!/bin/bash
#
# setup_cloudflare_tunnel.sh
# Set a cloudflared tunnel and define the JENKINS_TUNNEL_URL env var. 
# This is required to get a public URL to receive a GitHub Webhook when 
# Jenkins runs locally
#
# Use in other script : source ./cloudflare/setup_cloudflare_tunnel.sh
#
# Called by jenkins_install/jenkins_local_install.sh (--tunnel) at installation
# and by jenkins_install/setup_github_webhook.sh on every run 
# (because the tunnel URL changes each time cloudflared restarts).

_CF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_CF_DIR}/../env_install/env_shared_library.sh"

command -v cloudflared >/dev/null || {
  echo "cloudflared not found. Install it with:"
  echo "  curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb"
  echo "  sudo dpkg -i /tmp/cloudflared.deb"
  return 1 2>/dev/null || exit 1
}

####################################################################################################
# Reuse an already running tunnel from a previous call in this session,
# instead of starting a second one on top of it.
####################################################################################################
if [ -n "${JENKINS_TUNNEL_PID:-}" ] && kill -0 "${JENKINS_TUNNEL_PID}" 2>/dev/null; then
  echo "Reusing existing tunnel (pid ${JENKINS_TUNNEL_PID}): ${JENKINS_TUNNEL_URL}"
  return 0 2>/dev/null || exit 0
fi

echo ""
echo "=== Starting a Cloudflare tunnel to localhost:8080 ==="

CF_LOG="/tmp/cloudflared-jenkins.log"
cloudflared tunnel --url "http://localhost:8080" > "${CF_LOG}" 2>&1 &
CF_PID=$!

sleep 8
TUNNEL_URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "${CF_LOG}" | head -1)

if [ -z "${TUNNEL_URL}" ]; then
  echo "Tunnel failed to start — see ${CF_LOG}"
  kill "${CF_PID}" 2>/dev/null || true
  return 1 2>/dev/null || exit 1
fi

set_env JENKINS_TUNNEL_URL "${TUNNEL_URL}"
set_env JENKINS_TUNNEL_PID "${CF_PID}"

echo "Tunnel ready : ${JENKINS_TUNNEL_URL}  (pid ${JENKINS_TUNNEL_PID})"
echo "Note: this URL changes every time the tunnel restarts — re-run this"
echo "script (or setup_github_webhook.sh) to refresh the GitHub webhook."
echo "To stop it: kill ${JENKINS_TUNNEL_PID}"