#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
PROBE_DIR="$ROOT/scratch/eta_otel_v2/r_t3_exporter_on_eta_http"
OUT_DIR="$PROBE_DIR/out"
OTEL_PORT="${OTEL_PORT:-4318}"
OTEL_SPANS="${OTEL_SPANS:-1000}"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/traces.json"

COLLECTOR_PID=""
USE_DOCKER=0

cleanup() {
  if [ "$USE_DOCKER" -eq 1 ]; then
    docker compose -f "$PROBE_DIR/docker-compose.yml" down -v >/dev/null 2>&1 || true
  fi
  if [ -n "$COLLECTOR_PID" ] && kill -0 "$COLLECTOR_PID" >/dev/null 2>&1; then
    kill "$COLLECTOR_PID" >/dev/null 2>&1 || true
    wait "$COLLECTOR_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

collector_logs() {
  if [ "$USE_DOCKER" -eq 1 ]; then
    docker compose -f "$PROBE_DIR/docker-compose.yml" logs --no-color
  elif [ -f "$OUT_DIR/otelcol.log" ]; then
    cat "$OUT_DIR/otelcol.log"
  fi
}

if docker info >/dev/null 2>&1; then
  USE_DOCKER=1
  docker compose -f "$PROBE_DIR/docker-compose.yml" up -d
else
  ETA_R_T3_TRACE_FILE="$OUT_DIR/traces.json" \
    nix run nixpkgs#opentelemetry-collector-contrib -- \
    --config "$PROBE_DIR/otelcol-config.yaml" >"$OUT_DIR/otelcol.log" 2>&1 &
  COLLECTOR_PID="$!"
fi

ready=0
for _ in $(seq 1 60); do
  if curl -s -o /dev/null "http://127.0.0.1:$OTEL_PORT/v1/traces"; then
    ready=1
    break
  fi
  if [ -n "$COLLECTOR_PID" ] && ! kill -0 "$COLLECTOR_PID" >/dev/null 2>&1; then
    collector_logs
    echo "R-T3 failed: local collector exited before becoming ready" >&2
    exit 1
  fi
  sleep 0.5
done

if [ "$ready" -ne 1 ]; then
  collector_logs
  echo "R-T3 failed: collector did not become ready on port $OTEL_PORT" >&2
  exit 1
fi

EIO_BACKEND=posix nix develop -c dune exec \
  bench/r_t3_exporter_on_eta_http/r_t3_eta_http_otlp.exe -- \
  127.0.0.1 "$OTEL_PORT" "$OTEL_SPANS"

for _ in $(seq 1 40); do
  if [ -s "$OUT_DIR/traces.json" ]; then
    break
  fi
  sleep 0.25
done

if [ ! -s "$OUT_DIR/traces.json" ]; then
  collector_logs
  echo "R-T3 failed: collector did not write traces.json" >&2
  exit 1
fi

count="$(rg -o 'r_t3\.span\.' "$OUT_DIR/traces.json" | wc -l | tr -d ' ')"
if [ "$count" -lt "$OTEL_SPANS" ]; then
  collector_logs
  echo "R-T3 failed: expected at least $OTEL_SPANS spans, observed $count" >&2
  exit 1
fi

bytes="$(wc -c < "$OUT_DIR/traces.json" | tr -d ' ')"
echo "r_t3_collector_ingest spans=$count bytes=$bytes"
