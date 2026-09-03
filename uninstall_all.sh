#!/bin/bash
#
# uninstall_all.sh
# Tears down everything this project may have created: all 4 app
# instances, the Jenkins-on-AWS instance, the local Jenkins stack
# (including its job history), and every resource individual
# *_uninstall.sh scripts leave alone on purpose (security groups, the
# SSH key) -- since nothing is left running that could still need them.
#
# The DockerHub and ECR registries get their own separate confirmation,
# since deleting them destroys real images, not just test infrastructure.
#
# Usage: ./uninstall_all.sh
#
set -e
cd "$(dirname "$0")"

source ./env_install/env_shared_library.sh

echo ""
echo "This will terminate every app/Jenkins EC2 instance, tear down the local"
echo "Jenkins stack (including job history), and delete the shared security"
echo "groups and SSH key. This cannot be undone."
read -p "Continue? [y/N] " CONFIRM
[ "${CONFIRM}" = "y" ] || [ "${CONFIRM}" = "Y" ] || { echo "Aborted."; exit 0; }

echo ""
echo "=== 1/5 — Uninstalling app instances (all 4 combos) ==="
for registry in dockerhub ecr; do
  for transport in ssh ssm; do
    ./aws_ec2_install/aws_ec2_app_uninstall.sh "${registry}" "${transport}"
  done
done

echo ""
echo "=== 2/5 — Uninstalling the Jenkins-on-AWS instance ==="
./aws_ec2_install/aws_ec2_jenkins_uninstall.sh

echo ""
echo "=== 3/5 — Uninstalling the local Jenkins stack (including job history) ==="
./jenkins_install/jenkins_local_uninstall.sh --purge

echo ""
echo "=== 4/5 — Removing shared security groups and SSH key ==="
echo "Waiting for instances' network interfaces to fully detach..."
sleep 10
for sg in app-ec2-ssh-sg app-ec2-ssm-sg; do
  sg_id=$(aws ec2 describe-security-groups --group-names "${sg}" \
            --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v -e None -e '^$' || true)
  if [ -n "${sg_id}" ]; then
    aws ec2 delete-security-group --group-id "${sg_id}" 2>/dev/null && \
      echo "Deleted security group ${sg} (${sg_id})" || \
      echo "⚠️  Could not delete ${sg} yet — retry manually in a minute if needed."
  fi
done

echo "Deleting SSH key pair app-ec2-ssh-key..."
aws ec2 delete-key-pair --key-name app-ec2-ssh-key 2>/dev/null || true
rm -f aws_ec2_install/app-ec2-ssh-key.pem

sed -i '/^APP_EC2_SG_ID=/d' "${ENV_FILE}"

echo ""
echo "=== 5/5 — Registries (DockerHub + ECR) ==="
echo "This deletes the demo-java-app repository entirely on both registries,"
echo "including every image tag -- the one step that destroys real"
echo "artifacts, not just throwaway test infrastructure."
read -p "Also delete the DockerHub and ECR registries? [y/N] " CONFIRM_REGISTRIES

if [ "${CONFIRM_REGISTRIES}" = "y" ] || [ "${CONFIRM_REGISTRIES}" = "Y" ]; then
  if [ -n "${DOCKER_USERNAME:-}" ] && [ -n "${DOCKERHUB_PAT:-}" ]; then
    echo "Deleting DockerHub repository ${DOCKER_USERNAME}/demo-java-app..."
    JWT=$(printf '{"username":"%s","password":"%s"}' "${DOCKER_USERNAME}" "${DOCKERHUB_PAT}" \
            | curl -s --max-time 15 -X POST "https://hub.docker.com/v2/users/login" \
                -H "Content-Type: application/json" -d @- \
            | grep -o '"token":"[^"]*' | cut -d'"' -f4)
    if [ -n "${JWT}" ]; then
      STATUS=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' -X DELETE \
        "https://hub.docker.com/v2/repositories/${DOCKER_USERNAME}/demo-java-app/" \
        -H "Authorization: Bearer ${JWT}")
      # 202: queued deletion accepted. 204: deleted synchronously.
      # 404: already gone (e.g. a previous run already deleted it).
      if [ "${STATUS}" = "202" ] || [ "${STATUS}" = "204" ]; then
        echo "Deleted DockerHub repository (queued, HTTP ${STATUS})."
      elif [ "${STATUS}" = "404" ]; then
        echo "No DockerHub repository ${DOCKER_USERNAME}/demo-java-app — already gone."
      else
        echo "⚠️  DockerHub deletion returned HTTP ${STATUS}."
      fi
    else
      echo "⚠️  Could not authenticate to DockerHub — skipping."
    fi
  else
    echo "No DOCKER_USERNAME/DOCKERHUB_PAT in .env — skipping DockerHub."
  fi

  echo "Deleting ECR repository demo-java-app..."
  aws ecr delete-repository --repository-name demo-java-app --force 2>/dev/null && \
    echo "Deleted ECR repository." || \
    echo "No demo-java-app ECR repository — nothing to delete."
  sed -i '/^ECR_REGISTRY=/d' "${ENV_FILE}"
else
  echo "Keeping both registries."
fi

echo ""
echo "✅ Full uninstall complete."
echo ""