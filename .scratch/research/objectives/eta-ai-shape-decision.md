# eta-ai shape decision

Status: accepted.

This document records the accepted eta-ai API-shape decisions that constrain
eta-ai core and provider packages.

No production eta-ai code existed when this document was written.

## Verdict Summary

| Probe | Verdict | Phase A-C consequence |
| --- | --- | --- |
| A1 provider diff | Provider values with data fields plus small encode/decode functions. Per-provider modules are not justified for v1. | AC2 should define a provider record, not a functor/module-only provider API. |
| A2 streaming SSE | SSE parsing works over eta-http Body.Stream, but Eta_stream needs an owned effect-reader source before public streaming returns Eta_stream.Stream. | Public streaming is blocked on the eta-stream source primitive or must stay internal/non-public. |
| A3 schema | eta-schema cannot emit provider JSON Schema today. | AC4 uses caller-supplied raw JSON schemas in v1 unless eta-schema JSON Schema export lands first. |
| A4 tokenizer | Tokenizer deferred. Byte-count estimates are too wrong for preflight token budgeting. | No preflight token-budget API in v1; preserve provider usage fields after calls. |
| A5 telemetry | OTel GenAI semantic-convention names map cleanly to Eta.Tracer spans. | AC5 uses the A5 attribute set and suppresses provider HTTP transport spans by default. |

## Provider Shape

eta-ai core should expose one common provider value shape. Provider packages
construct values of that shape.

Required provider fields:

- provider name;
- base URL;
- chat/messages path;
- auth/header builder;
- capability flags;
- encode_chat;
- decode_chat;
- decode_stream_event;
- decode_error.

The provider value may contain functions. A1 rejected data-only providers
because Anthropic is structurally different from OpenAI in request envelopes,
response content blocks, tool_use/tool_result, named SSE events, and error
shape.

The provider value should not own application state. Applications own state;
Eta owns effect description and interpretation.

## Streaming

eta-http is sufficient at the body layer:

- Body.Stream.read supports pull parsing.
- Body.Stream.discard releases the upstream body.
- release is idempotent.

eta-stream is missing the public source primitive needed for public AI streams:

- Mailbox.to_stream does not own producer cancellation.
- from_eio_stream has no EOF/finalizer.
- parsing the whole response loses streaming and bounded memory.

Filed extension:

- packages/eta-stream/docs/adrs/0001-effect-reader-stream.md

Until that lands, eta-ai Phase A-C may implement internal streaming probes, but
the public v1 API should not promise Eta_stream.Stream-backed provider streams.

## Tool Schemas

Provider APIs require JSON Schema documents:

- OpenAI function parameters and structured output schemas.
- Anthropic tool input_schema.

eta-schema currently provides runtime codecs, not JSON Schema export.

Filed extension:

- packages/eta-schema/docs/adrs/0001-json-schema-export.md

eta-ai v1 should accept raw JSON schemas supplied by callers. A later version can
add typed eta-schema integration after the exporter lands.

## Token Usage

eta-ai v1 should preserve provider usage metadata:

- OpenAI prompt/completion/total tokens.
- Anthropic input/output/cache token fields.
- OpenRouter prompt/completion/total token usage and cost metadata.

eta-ai v1 should not expose a preflight token-budget API. The A4 tiktoken probe
showed byte/4 underestimating a small OCaml code prompt by 42.86 percent.

Applications that need preflight budgeting in v1 may provide their own tokenizer
outside eta-ai.

## Telemetry

Source:

- OpenTelemetry semantic-conventions-genai repository.
- model/gen-ai/spans.yaml
- model/gen-ai/registry.yaml
- Source status: development.

eta-ai v1 spans:

- chat {model}, kind Client;
- embeddings {model}, kind Client;
- execute_tool {tool_name}, kind Internal;
- streaming chat uses the same chat span shape with gen_ai.request.stream=true.

Default attributes:

- gen_ai.operation.name;
- gen_ai.provider.name;
- gen_ai.request.model;
- server.address;
- server.port;
- gen_ai.response.id when available;
- gen_ai.response.model when available;
- gen_ai.response.finish_reasons when available;
- gen_ai.usage.input_tokens when available;
- gen_ai.usage.output_tokens when available;
- gen_ai.request.stream only for streaming calls;
- gen_ai.response.time_to_first_chunk when streaming and measured.

Sensitive content attributes are opt-in only:

- gen_ai.system_instructions;
- gen_ai.input.messages;
- gen_ai.output.messages;
- gen_ai.tool.call.arguments;
- gen_ai.tool.call.result.

Eta.Tracer attributes are string pairs today. eta-ai v1 should follow the
existing eta-http precedent and emit stringified values. Typed OTel attributes
are a general Eta tracer/exporter improvement, not an eta-ai-local workaround.

Provider HTTP calls should use eta-http with observability suppressed by default
inside AI spans. Low-level HTTP tracing can be an explicit caller option later.

## Evidence

- .scratch/research/evidence/eta_ai_v1/probes/provider_diff/
- .scratch/research/evidence/eta_ai_v1/probes/streaming_sse/
- .scratch/research/evidence/eta_ai_v1/probes/schema/
- .scratch/research/evidence/eta_ai_v1/probes/tokenizer/
- .scratch/research/evidence/eta_ai_v1/probes/telemetry/
- .scratch/research/journal.md entries V-AI-A1 through V-AI-A5

## Open Risks

- OpenAI-compatible providers can hide vendor-specific quirks. AP3 needs real
  recorded fixtures for at least two compatible providers.
- Public streaming needs the eta-stream source primitive before it is safe to
  expose as Eta_stream.Stream.
- Typed tool schemas require eta-schema JSON Schema export.
- Tokenizer support remains a v1.x feature.
- OTel GenAI conventions are still development-status; eta-ai should pin the
  source used in docs and avoid pretending the names are stable.
