#!/usr/bin/env bash
# Prove a backup restores: load it into a separate scratch database in the same
# PostgreSQL pod, compare the row count with the count recorded at backup time,
# then drop the scratch database. Never touches the live database.
#   restore-test.sh [s3-key]      (default: the newest backup)
set -euo pipefail

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
REGION=ap-south-1
NAMESPACE=snipr
POD=snipr-postgres-0
SCRATCH=snipr_restore_test

log() { printf '%s restore-test: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }
for cmd in aws kubectl gzip; do command -v "$cmd" >/dev/null || die "missing command: $cmd"; done

account=$(aws sts get-caller-identity --query Account --output text --region "$REGION") || die "no AWS identity"
bucket="snipr-backups-$account"
key=${1:-$(aws s3api list-objects-v2 --bucket "$bucket" --prefix db/snipr- --region "$REGION" \
  --query 'Contents[].Key' --output text | tr '\t' '\n' | sort | tail -n 1)}
[[ $key =~ ^db/snipr-[0-9]{8}T[0-9]{6}Z\.sql\.gz$ ]] || die "no valid backup key: '$key'"

live_db=$(kubectl -n "$NAMESPACE" exec "$POD" -- printenv POSTGRES_DB </dev/null)
[[ $SCRATCH != "$live_db" ]] || die "scratch database name equals the live database"
# -i passes stdin to psql; calls that send no SQL on stdin use </dev/null so they
# do not swallow the caller's input.
psql() { kubectl -n "$NAMESPACE" exec -i "$POD" -- sh -c "psql -U \"\$POSTGRES_USER\" -v ON_ERROR_STOP=1 -q $*"; }

expected=$(aws s3api head-object --bucket "$bucket" --key "$key" --region "$REGION" \
  --query 'Metadata."links-rows"' --output text) || die "cannot read backup metadata"
log "restoring $key (expects $expected link rows) into scratch database $SCRATCH"

psql "-d postgres -c 'DROP DATABASE IF EXISTS $SCRATCH' -c 'CREATE DATABASE $SCRATCH'" </dev/null # scratch only
aws s3 cp "s3://$bucket/$key" - --region "$REGION" --only-show-errors | gzip -dc |
  psql "-d $SCRATCH" >/dev/null || die "restore failed"

restored=$(psql "-d $SCRATCH -tA -c 'SELECT count(*) FROM links'" </dev/null)
live=$(psql "-d $live_db -tA -c 'SELECT count(*) FROM links'" </dev/null)
log "link rows: backup $expected, restored $restored, live now $live"
psql "-d postgres -c 'DROP DATABASE $SCRATCH'" </dev/null
[[ $restored == "$expected" ]] || die "row count mismatch"
log "restore test passed"
