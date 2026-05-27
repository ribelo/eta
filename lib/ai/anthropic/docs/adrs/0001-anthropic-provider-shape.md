# ADR 0001: Anthropic Provider Shape

## Status

Accepted for the offline AP2 implementation. Live reach remains a release gate.

## Context

Phase A-R found that Anthropic is the provider that falsifies a data-only
provider shape. It uses /v1/messages, x-api-key plus anthropic-version headers,
top-level system prompts, user/assistant content blocks, tool_use/tool_result
blocks, named SSE events, and prompt-cache controls.

AP2 needs to validate that those differences still fit eta-ai's provider value
and eta-http runner model without adding SDKs, tokenizers, or ambient
framework state.

## Decision

eta-ai-anthropic exports a provider value plus eta-http runners:

- provider () targets /v1/messages.
- encode_messages builds the Anthropic Messages API envelope from eta-ai
  chat_request.
- messages and stream_messages submit requests through eta-http and suppress
  nested provider transport observability.
- prompt_cache adds the Anthropic beta header and can encode system text as an
  ephemeral cache_control text block.

Anthropic requires max_tokens, so eta-ai-anthropic rejects requests where
max_output_tokens is None.

The package keeps provider SDKs out of the dependency graph; structured JSON may
use the repository's normal Yojson dependency.

## Evidence

Offline fixture tests cover:

- provider metadata, x-api-key, anthropic-version, and beta headers;
- Messages API request encoding with top-level system text, tools, tool_result
  blocks, required max_tokens, and prompt cache controls;
- non-stream message decoding for text and usage, including cache usage fields;
- tool_use response decoding into eta-ai tool calls;
- Anthropic named SSE event decoding for message_start, text_delta,
  input_json_delta, message_delta, message_stop, and error;
- eta-http request construction through Client.make_for_test;
- provider error decoding for non-2xx responses;
- suppression of nested eta-http transport spans under the GenAI chat span.

Focused command:

    nix develop -c dune runtest lib/ai/anthropic --force

## Consequences

- eta-http is sufficient for AP2 request submission, response-body reads, and
  streaming body ownership.
- eta-ai core does not need Anthropic-specific message or runtime ownership.
- eta-ai's current message vocabulary can express prompt-cache headers and
  system-block cache_control, but not arbitrary per-block cache metadata.
- Offline fixtures are not proof of live provider behavior. AP2 should not be
  treated as release-complete until an Anthropic canary reach probe runs with a
  real key and the fixture corpus is refreshed from that interaction.
