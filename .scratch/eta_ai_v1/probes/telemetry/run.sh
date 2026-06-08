#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../../.."

RESULTS="scratch/eta_ai_v1/probes/telemetry/results"
LOG="$RESULTS/telemetry_probe.txt"
mkdir -p "$RESULTS"
: > "$LOG"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'missing command: %s\n' "$1" >&2
    exit 127
  fi
}

check_url() {
  local name="$1"
  local url="$2"
  shift 2

  local tmp
  tmp="$(mktemp -t eta-ai-telemetry.XXXXXX)"

  curl --fail --location --silent --show-error --max-time 30 "$url" > "$tmp"
  local pattern
  for pattern in "$@"; do
    if ! rg -F -q "$pattern" "$tmp"; then
      printf 'missing %s :: %s\n' "$name" "$pattern" | tee -a "$LOG" >&2
      rm -f "$tmp"
      exit 1
    fi
  done

  printf 'ok %s\n' "$name" | tee -a "$LOG" >/dev/null
  rm -f "$tmp"
}

need curl
need dune
need rg

check_url \
  otel-genai-spans \
  https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/model/gen-ai/spans.yaml \
  'type: gen_ai.inference.client' \
  'type: gen_ai.embeddings.client' \
  'type: gen_ai.execute_tool.internal' \
  'gen_ai.request.stream' \
  'gen_ai.response.time_to_first_chunk'

check_url \
  otel-genai-registry \
  https://raw.githubusercontent.com/open-telemetry/semantic-conventions-genai/main/model/gen-ai/registry.yaml \
  'gen_ai.provider.name' \
  'gen_ai.operation.name' \
  'gen_ai.request.model' \
  'gen_ai.usage.input_tokens' \
  'gen_ai.usage.output_tokens' \
  'gen_ai.tool.name'

dune exec scratch/eta_ai_v1/probes/telemetry/telemetry_probe.exe \
  | tee -a "$LOG"
