#!/usr/bin/env bash
# Back up the snipr PostgreSQL database to S3: pg_dump -> gzip -> verify -> upload
# -> verify -> keep the newest 7. Runs as root on the node (cron, daily).
# Installed by "make node-scripts" to /opt/snipr/bin.
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
REGION=ap-south-1
NAMESPACE=snipr
POD=snipr-postgres-0
PREFIX=db/
KEEP=7

log() { printf '%s backup: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
for cmd in aws kubectl gzip awk; do command -v "$cmd" >/dev/null || die "missing command: $cmd"; done

account=$(aws sts get-caller-identity --query Account --output text --region "$REGION") || die "no AWS identity"
bucket="snipr-backups-$account"
key="${PREFIX}snipr-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"

umask 077
tmp=$(mktemp -d /var/tmp/snipr-backup.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
file="$tmp/dump.sql.gz"

# Runs inside the pod, over its local socket, so no password is needed or logged.
# shellcheck disable=SC2016 # the variables expand inside the pod, not here
kubectl -n "$NAMESPACE" exec "$POD" -- sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges' |
  gzip -9 > "$file" || die "pg_dump failed"

gzip -t "$file" || die "gzip integrity check failed"
gzip -dc "$file" | tail -n 5 | grep -q 'PostgreSQL database dump complete' || die "dump is truncated"
# Rows of the links table inside this dump (COPY block), for the restore test.
rows=$(gzip -dc "$file" | awk '/^COPY public\.links /{on=1; next} on && /^\\\.$/{on=0} on{n++} END{print n+0}')
size=$(stat -c %s "$file")
log "dump ok: $size bytes, $rows link rows"

aws s3 cp "$file" "s3://$bucket/$key" --region "$REGION" --only-show-errors \
  --sse AES256 --metadata "links-rows=$rows" || die "upload failed"
remote=$(aws s3api head-object --bucket "$bucket" --key "$key" --region "$REGION" --query ContentLength --output text) ||
  die "uploaded object not found"
[[ $remote == "$size" ]] || die "size mismatch after upload: local $size, S3 $remote"
log "uploaded s3://$bucket/$key ($remote bytes)"

# Retention runs only after the new backup is verified, and only on our own names.
mapfile -t keys < <(aws s3api list-objects-v2 --bucket "$bucket" --prefix "${PREFIX}snipr-" --region "$REGION" \
  --query 'Contents[].Key' --output text | tr '\t' '\n' | grep -E '^db/snipr-[0-9]{8}T[0-9]{6}Z\.sql\.gz$' | sort)
count=${#keys[@]}
if (( count > KEEP )); then
  for old in "${keys[@]:0:count-KEEP}"; do
    [[ $old == "$key" ]] && continue # never the backup just made
    aws s3 rm "s3://$bucket/$old" --region "$REGION" --only-show-errors || die "could not delete $old"
    log "deleted old backup $old"
  done
fi
log "done: $(( count > KEEP ? KEEP : count )) backups kept"
