#!/bin/bash
#
# jenkins_local_uninstall.sh
# Tears down the local Jenkins stack: containers, network, and (optionally)
# the persistent volume holding Jenkins' own state (jobs, build history).
# Also removes the local IAM user created for ECR/SSM combos, if any.
#
# Usage:
#   ./jenkins_local_uninstall.sh            # keep the jenkins_home volume
#   ./jenkins_local_uninstall.sh --purge    # also delete the volume (jobs, history)
#
set -e
cd "$(dirname "$0")"    # Runs the script into this folder

source ../env_install/env_shared_library.sh

echo ""
echo "=== Uninstalling the local Jenkins stack ==="

sudo docker compose --env-file ../.env down

if [ "${1:-}" = "--purge" ]; then
  echo "Removing the jenkins_home volume (all jobs/build history)..."
  sudo docker volume rm jenkins_install_jenkins_home 2>/dev/null || true
else
  echo "Keeping the jenkins_home volume — rerun with --purge to also delete it."
fi

echo "Removing built agent/controller images..."
sudo docker rmi -f jenkins-controller jenkins-docker-aws-agent jenkins-maven-agent jenkins-base-agent 2>/dev/null || true

# Leftover app images: the pipeline's own cleanup always keeps the
# currently-deployed tag of each combo, so one demo-java-app image per
# registry survives every run -- nothing else ever removes those.
echo "Removing leftover demo-java-app images..."
sudo docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
  | awk '$1 ~ /demo-java-app/ {print $2}' | xargs -r sudo docker rmi -f

# Every docker-aws-agent container run leaves behind anonymous volumes
# (build cache, etc.) that surviving container removal doesn't clean up.
# Excludes jenkins_install_jenkins_home explicitly -- "docker volume prune"
# would remove it too even without --purge, since compose down above
# already detached it from any container.
echo "Pruning orphaned Docker volumes..."
sudo docker volume ls -qf dangling=true \
  | grep -v '^jenkins_install_jenkins_home$' \
  | xargs -r sudo docker volume rm

# The local IAM user is only created when an ECR/SSM combo is tested locally.
if aws iam get-user --user-name jenkins-local-aws-creds >/dev/null 2>&1; then
  echo "Removing local IAM user jenkins-local-aws-creds..."
  for key_id in $(aws iam list-access-keys --user-name jenkins-local-aws-creds \
                    --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    aws iam delete-access-key --user-name jenkins-local-aws-creds --access-key-id "${key_id}"
  done
  for policy_arn in $(aws iam list-attached-user-policies --user-name jenkins-local-aws-creds \
                        --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-user-policy --user-name jenkins-local-aws-creds --policy-arn "${policy_arn}"
  done
  aws iam delete-user --user-name jenkins-local-aws-creds
fi

# Kill the Cloudflare tunnel process too -- the .env cleanup below only
# removes its PID, it never stops the process itself.
if [ -n "${JENKINS_TUNNEL_PID:-}" ]; then
  kill "${JENKINS_TUNNEL_PID}" 2>/dev/null || true
fi

sed -i '/^JENKINS_ADMIN_USER=/d;/^JENKINS_ADMIN_PASSWORD=/d;/^DOCKER_GID=/d;/^JENKINS_INGRESS_IP=/d;/^LOCAL_INGRESS_IP=/d;/^JENKINS_TARGET=/d;/^JENKINS_AWS_ACCESS_KEY_ID=/d;/^JENKINS_AWS_SECRET_ACCESS_KEY=/d;/^JENKINS_TUNNEL_URL=/d;/^JENKINS_TUNNEL_PID=/d;/^JENKINS_URL=/d' "${ENV_FILE}"

echo ""
echo "✅ Local Jenkins stack uninstalled."
echo ""