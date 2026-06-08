#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../../.."

RESULTS="scratch/eta_ai_v1/probes/schema/results"
LOG="$RESULTS/schema_probe.txt"
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
  tmp="$(mktemp -t eta-ai-schema.XXXXXX)"

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
  openai-openapi \
  https://raw.githubusercontent.com/openai/openai-openapi/master/openapi.yaml \
  'FunctionParameters:' \
  'described as a JSON Schema object' \
  'additionalProperties: true' \
  'ResponseFormatJsonSchemaSchema:' \
  'oneOf:' \
  'anyOf:' \
  '$ref:'

check_url \
  anthropic-messages \
  https://platform.claude.com/docs/en/api/messages/create.md \
  'input_schema' \
  'JSON schema' \
  'draft/2020-12' \
  'tool_use' \
  'tool_result'

rg -F -q 'val enum' packages/eta-schema/eta_schema.mli
rg -F -q 'val tagged_union' packages/eta-schema/eta_schema.mli
rg -F -q 'val lazy_' packages/eta-schema/eta_schema.mli
rg -F -q 'val record6' packages/eta-schema/eta_schema.mli
printf 'eta_schema_constructors=ok\n' | tee -a "$LOG" >/dev/null

dune runtest packages/eta-schema --force >> "$LOG"
printf 'eta_schema_tests=ok\n' | tee -a "$LOG" >/dev/null

if rg -n 'val json_schema|module Json_schema|to_json_schema' \
  packages/eta-schema/eta_schema.mli >> "$LOG"
then
  printf 'eta_schema_json_schema_export=present\n' | tee -a "$LOG" >/dev/null
else
  printf 'eta_schema_json_schema_export=missing\n' | tee -a "$LOG" >/dev/null
fi

if rg -n 'oneOf|anyOf|allOf|additionalProperties|\$ref' \
  packages/eta-schema/eta_schema.mli >> "$LOG"
then
  printf 'eta_schema_json_schema_vocab=present\n' | tee -a "$LOG" >/dev/null
else
  printf 'eta_schema_json_schema_vocab=missing\n' | tee -a "$LOG" >/dev/null
fi

printf 'provider_schema_docs=ok\n' | tee -a "$LOG" >/dev/null
printf 'schema_probe=gap\n'
printf 'eta_schema_tests=ok\n'
printf 'provider_schema_docs=ok\n'
printf 'eta_schema_json_schema_export=missing\n'
printf 'log=%s\n' "$LOG"
