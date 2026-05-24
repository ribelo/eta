#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../../.."

RESULTS="scratch/eta_ai_v1/probes/tokenizer/results"
LOG="$RESULTS/tokenizer_probe.txt"
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
  tmp="$(mktemp -t eta-ai-tokenizer.XXXXXX)"

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
need rg
need uv

check_url \
  openai-openapi \
  https://raw.githubusercontent.com/openai/openai-openapi/master/openapi.yaml \
  'prompt_tokens' \
  'completion_tokens' \
  'total_tokens'

check_url \
  anthropic-messages \
  https://platform.claude.com/docs/en/api/messages/create.md \
  'usage: Usage' \
  'input_tokens' \
  'output_tokens' \
  'will not match one-to-one with the exact visible content'

check_url \
  openrouter-chat \
  https://openrouter.ai/docs/api/api-reference/chat/send-chat-completion-request.mdx \
  'Token usage statistics' \
  'prompt_tokens' \
  'completion_tokens' \
  'total_tokens'

uv run --with tiktoken python scratch/eta_ai_v1/probes/tokenizer/token_probe.py \
  | tee -a "$LOG"
