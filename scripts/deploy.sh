#!/usr/bin/env bash
# Deploy one chart version + image to k3s. CD calls this through SSM Run Command:
#   deploy.sh <chart-version> <image-sha> <base-url>
# Only these three non-secret values travel through SSM; the chart references the
# database Secret "snipr-db" by name. Installed by "make node-scripts"; runs as root.
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
REGION=ap-south-1
NAMESPACE=snipr

log() { printf '%s deploy: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ $# -eq 3 ]] || die "usage: deploy.sh <chart-version> <image-sha> <base-url>"
version=$1 sha=$2 base_url=$3
# Strict formats: these values arrive over SSM and end up in a command line.
[[ $version =~ ^0\.1\.[0-9]+$ ]] || die "bad chart version: $version"
[[ $sha =~ ^[0-9a-f]{40}$ ]] || die "bad image SHA: $sha"
[[ $base_url =~ ^http://[0-9.]+$ ]] || die "bad base URL: $base_url"
for cmd in aws helm kubectl; do command -v "$cmd" >/dev/null || die "missing command: $cmd"; done

account=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
registry="$account.dkr.ecr.$REGION.amazonaws.com"

/opt/snipr/bin/ecr-refresh.sh # fresh pull secret for any new pods
aws ecr get-login-password --region "$REGION" |
  helm registry login --username AWS --password-stdin "$registry" >/dev/null # domain only (Helm 4)

log "deploying chart $version, image $sha"
helm upgrade --install snipr "oci://$registry/charts/snipr" --version "$version" \
  -n "$NAMESPACE" \
  --set image.repository="$registry/snipr" --set image.tag="$sha" --set baseUrl="$base_url" \
  --rollback-on-failure --wait --timeout 3m

helm status snipr -n "$NAMESPACE"
running=$(kubectl -n "$NAMESPACE" get deploy snipr -o jsonpath='{.spec.template.spec.containers[0].image}')
log "running image: ${running##*/}"
[[ $running == *":$sha" ]] || die "running image does not match $sha"
log "deploy ok"
