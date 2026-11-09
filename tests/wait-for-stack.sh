#!/usr/bin/env bash
# Waits until Grafana (LGTM) and the given engines from dev/docker-compose.yml are ready for
# tests/run-integration.ps1. Usage: tests/wait-for-stack.sh lucee7 acf2023 ...
# ACF restarts itself once during first-boot setup, so an engine only counts as ready after
# answering continuously for a while, not on its first 200.
set -euo pipefail

declare -A PORT=([lucee7]=8971 [lucee6]=8961 [acf]=8951 [acf2023]=8941)
TIMEOUT="${TIMEOUT:-900}"   # seconds, per component
GRAFANA="${GRAFANA:-http://localhost:3000}"

wait_for() { # <label> <stable seconds> <url>
  local label="$1" stable="$2" url="$3" start ok_since=0 now
  start=$(date +%s)
  while :; do
    now=$(date +%s)
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url")" == "200" ]]; then
      (( ok_since == 0 )) && ok_since=$now
      if (( now - ok_since >= stable )); then echo "$label ready after $(( now - start ))s"; return 0; fi
    else
      ok_since=0
    fi
    if (( now - start > TIMEOUT )); then echo "$label not ready after ${TIMEOUT}s ($url)" >&2; return 1; fi
    sleep 5
  done
}

for ds in Tempo Prometheus Loki; do
  wait_for "grafana datasource $ds" 0 "$GRAFANA/api/datasources/name/$ds"
done
for e in "$@"; do
  [[ -n "${PORT[$e]:-}" ]] || { echo "unknown engine: $e" >&2; exit 2; }
  stable=15; [[ "$e" == acf* ]] && stable=60
  wait_for "$e" "$stable" "http://localhost:${PORT[$e]}/cfml-otel/tests/app/check.cfm"
done
