#!/usr/bin/env bash
# Refresh the "ecr-creds" image pull secret from the node's IAM role.
# ECR tokens expire after 12 hours; cron runs this at boot and every 6 hours.
# Installed by "make node-scripts" to /opt/snipr/bin; runs as root.
set -euo pipefail

NAMESPACE="${NAMESPACE:-snipr}"
SECRET="${SECRET:-ecr-creds}"
REGION="${AWS_REGION:-ap-south-1}"
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

log() { printf '%s ecr-refresh: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

for cmd in aws kubectl jq base64; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

# At boot, k3s may still be starting.
for _ in $(seq 30); do
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 && break
  sleep 10
done
kubectl get namespace "$NAMESPACE" >/dev/null || die "namespace $NAMESPACE not reachable"

account=$(aws sts get-caller-identity --query Account --output text --region "$REGION") ||
  die "cannot read the AWS identity (instance role?)"
registry="$account.dkr.ecr.$REGION.amazonaws.com"

# The password goes through pipes only: never into argv (visible in ps) or logs.
password=$(aws ecr get-login-password --region "$REGION") || die "aws ecr get-login-password failed"
auth=$(printf 'AWS:%s' "$password" | base64 -w0)
unset password
jq -n --arg r "$registry" --arg a "$auth" '{auths: {($r): {auth: $a}}}' |
  kubectl create secret generic "$SECRET" -n "$NAMESPACE" \
    --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin \
    --dry-run=client -o yaml |
  kubectl apply -f - >/dev/null || die "kubectl apply failed"
unset auth

kubectl get secret "$SECRET" -n "$NAMESPACE" >/dev/null || die "secret missing after update"
log "refreshed secret $NAMESPACE/$SECRET for $registry"
