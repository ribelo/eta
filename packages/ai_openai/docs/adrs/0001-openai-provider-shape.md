# ADR 0001: OpenAI Provider Shape

## Status

Accepted for the offline AP1 implementation. Live reach remains a release gate.

## Context

eta-ai core exposes provider values, raw JSON tool schemas, SSE parsing over
eta-http bodies, and GenAI telemetry wrappers. AP1 needs the first real provider
package to validate that eta-http is sufficient for provider runners without
adding SDKs, tokenizers, or ambient framework state.

OpenAI has two related surfaces that eta-ai must understand:

- Responses API, with input messages, tools, structured outputs, and SSE
  event names.
- Explicit legacy Chat Completions compatibility for services or tests that
  still require messages, tools, structured outputs, and SSE chunks.

## Decision

eta-ai-openai exports provider values plus eta-http runners:

- provider () targets /v1/responses.
- responses_provider () targets /v1/responses.
- chat_completions_provider () targets /v1/chat/completions explicitly.
- encode_chat and encode_responses build provider JSON from eta-ai requests.
- responses and stream_responses are the primary runners. chat_completions and
  stream_chat_completions remain explicit legacy runners.

The package keeps provider SDKs out of the dependency graph; structured JSON may
use the repository's normal Yojson dependency.

## Evidence

Offline fixture tests cover:

- provider metadata and Authorization header construction;
- Responses request encoding with tools and structured outputs;
- explicit legacy Chat Completions request encoding with tools and structured
  outputs;
- Chat Completions text decoding;
- Chat Completions function-call decoding;
- Responses text and function-call decoding;
- OpenAI Responses SSE decoding, including tool argument deltas and done
  markers;
- eta-http request construction through Client.make_for_test;
- provider error decoding for non-2xx responses;
- suppression of nested eta-http transport spans under the GenAI chat span.

Focused command:

    nix develop -c dune runtest packages/eta-ai-openai --force

## Consequences

- eta-http is sufficient for AP1 request submission, response-body reads, and
  streaming body ownership.
- eta-ai core does not need to own provider HTTP clients or state.
- Provider JSON uses the shared Yojson-backed eta-ai helper surface.
- Offline fixtures are not proof of live provider behavior. AP1 should not be
  treated as release-complete until an OpenAI canary reach probe runs with a
  real key and the fixture corpus is refreshed from that interaction.
