#!/usr/bin/env bash
# First-boot setup for the snipr EC2 node: AWS CLI, k3s, Helm 4, namespaces.
# Terraform passes this file as user_data, so cloud-init runs it once as root.
# Safe to rerun by hand: sudo bash bootstrap-node.sh
# Log: /var/log/snipr-bootstrap.log
set -euo pipefail

K3S_VERSION="v1.37.2+k3s1"
HELM_VERSION="v4.3.0"
HELM_SHA256="86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb"
ADMIN_USER="ubuntu"
NAMESPACES=(snipr monitoring)
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

exec > >(tee -a /var/log/snipr-bootstrap.log) 2>&1
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
trap 'die "failed at line $LINENO"' ERR

[[ $EUID -eq 0 ]] || die "run as root"
log "bootstrap start"

# The Elastic IP is attached a few seconds after boot; until then there is no internet.
for _ in $(seq 60); do
  curl -sf --max-time 5 -o /dev/null https://get.k3s.io && break
  log "waiting for internet access"
  sleep 5
done
curl -sf --max-time 5 -o /dev/null https://get.k3s.io || die "no internet access after 5 minutes"

log "installing OS packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ca-certificates curl jq

if ! command -v aws >/dev/null; then
  log "installing AWS CLI"
  snap install aws-cli --classic
fi
log "aws: $(aws --version 2>&1)"

if ! command -v k3s >/dev/null || [[ "$(k3s --version | head -1)" != *"$K3S_VERSION"* ]]; then
  log "installing k3s $K3S_VERSION"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - --write-kubeconfig-mode 600
fi
log "waiting for the node to be Ready"
for _ in $(seq 60); do
  kubectl get nodes >/dev/null 2>&1 && break
  sleep 5
done
kubectl wait --for=condition=Ready node --all --timeout=300s
log "k3s: $(k3s --version | head -1)"

if [[ "$(helm version --short 2>/dev/null)" != "$HELM_VERSION"* ]]; then
  log "installing Helm $HELM_VERSION"
  tmp=$(mktemp -d)
  curl -sfL -o "$tmp/helm.tgz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  echo "$HELM_SHA256  $tmp/helm.tgz" | sha256sum -c --quiet || die "Helm checksum mismatch"
  tar -xzf "$tmp/helm.tgz" -C "$tmp"
  install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "$tmp"
fi
log "helm: $(helm version --short)"

# Ubuntu AMIs ship the SSM agent as a snap; CD depends on it.
snap services amazon-ssm-agent | grep -q ' active' || die "SSM agent is not running"
log "SSM agent active"

log "kubeconfig for $ADMIN_USER"
install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.kube"
install -m 0600 -o "$ADMIN_USER" -g "$ADMIN_USER" "$KUBECONFIG" "/home/$ADMIN_USER/.kube/config"
# Without this, k3s's kubectl reads the root-only /etc/rancher/k3s/k3s.yaml.
# shellcheck disable=SC2016 # $HOME must expand at login, not now
line='export KUBECONFIG="$HOME/.kube/config"'
grep -qxF "$line" "/home/$ADMIN_USER/.bashrc" || echo "$line" >> "/home/$ADMIN_USER/.bashrc"

for ns in "${NAMESPACES[@]}"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
log "namespaces: ${NAMESPACES[*]}"

# Cron jobs are added in later phases, once their scripts exist.
log "bootstrap complete"
