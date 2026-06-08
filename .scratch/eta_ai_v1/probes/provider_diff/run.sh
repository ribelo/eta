#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
RESULTS="$ROOT/results"
LOG="$RESULTS/doc-checks.txt"

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
  tmp="$(mktemp -t eta-ai-provider-diff.XXXXXX)"

  printf 'checking %s\n' "$name" | tee -a "$LOG" >/dev/null
  curl --fail --location --silent --show-error --max-time 30 "$url" > "$tmp"

  local pattern
  for pattern in "$@"; do
    if rg -F -q "$pattern" "$tmp"; then
      printf 'ok %s :: %s\n' "$name" "$pattern" | tee -a "$LOG" >/dev/null
    else
      printf 'missing %s :: %s\n' "$name" "$pattern" | tee -a "$LOG" >&2
      rm -f "$tmp"
      exit 1
    fi
  done

  rm -f "$tmp"
}

need curl
need rg

check_url \
  openai-openapi \
  https://raw.githubusercontent.com/openai/openai-openapi/master/openapi.yaml \
  '/chat/completions:' \
  'Authorization: Bearer $OPENAI_API_KEY' \
  'CreateChatCompletionRequest' \
  'CreateChatCompletionResponse' \
  'CreateChatCompletionStreamResponse' \
  'ChatCompletionMessageToolCall' \
  'data: [DONE]' \
  'ErrorResponse'

check_url \
  anthropic-auth \
  https://docs.anthropic.com/llms-full.txt \
  'curl https://api.anthropic.com/v1/messages' \
  'x-api-key: $ANTHROPIC_API_KEY' \
  'anthropic-version: 2023-06-01'

check_url \
  anthropic-messages \
  https://platform.claude.com/docs/en/api/messages/create.md \
  '/v1/messages' \
  'top-level' \
  'system' \
  'there is no' \
  'content blocks' \
  'tools: optional array of ToolUnion' \
  'tool_use' \
  'tool_result'

check_url \
  anthropic-streaming \
  https://platform.claude.com/docs/en/build-with-claude/streaming.md \
  'event: message_start' \
  'event: content_block_start' \
  'event: content_block_delta' \
  'event: message_delta' \
  'event: message_stop' \
  'input_json_delta' \
  'partial_json' \
  'event: error' \
  'overloaded_error'

check_url \
  openrouter-chat \
  https://openrouter.ai/docs/api/api-reference/chat/send-chat-completion-request.mdx \
  'POST https://openrouter.ai/api/v1/chat/completions' \
  'API key as bearer token in Authorization header' \
  'Supports both streaming and non-streaming modes' \
  'messages:' \
  'tools:' \
  'provider:' \
  'choices:'

check_url \
  openrouter-errors \
  https://openrouter.ai/docs/api/reference/errors-and-debugging.mdx \
  'For errors, OpenRouter returns a JSON response with the following shape:' \
  'metadata?: Record<string, unknown>;' \
  'Errors that occur after streaming has begun are sent as Server-Sent Events' \
  "finish_reason: 'error';"

check_url \
  openrouter-overview \
  https://openrouter.ai/docs/llms-full.txt \
  'compatible with any language or framework' \
  'OpenAI SDK pointed at OpenRouter as a drop-in replacement' \
  'HTTP-Referer' \
  'X-Title'

printf 'provider_diff_doc_checks=ok\n'
printf 'log=%s\n' "$LOG"
