#!/usr/bin/env bash
# Check /healthz and /readyz once; log only the status codes; exit 1 if either
# fails. Cron runs it every 5 minutes on the node.
set -euo pipefail

BASE_URL="${HEALTHCHECK_URL:-http://127.0.0.1}" # Traefik on the node
TIMEOUT=5

log() { printf '%s healthcheck: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
command -v curl >/dev/null || { log "ERROR: missing command: curl"; exit 1; }

failed=0
for endpoint in /healthz /readyz; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$BASE_URL$endpoint") || true
  if [[ $code == 200 ]]; then
    log "$endpoint ok ($code)"
  else
    log "$endpoint FAILED (${code:-000})"
    failed=1
  fi
done
exit "$failed"
