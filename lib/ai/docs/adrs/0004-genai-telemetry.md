# ADR 0004: GenAI Telemetry

Status: accepted.

## Context

AC5 needs eta-ai to emit OpenTelemetry GenAI-shaped spans while staying inside
Eta's tracer capability. A5 validated the current GenAI semantic-convention
names against chat, streaming chat, embeddings, and tool execution.

Eta tracer attributes are string pairs today. eta-ai therefore stringifies
attribute values instead of introducing a local typed-attribute layer.

Provider packages will call eta-http. Those transport calls should not create
nested HTTP spans inside every AI span unless the caller explicitly opts into
low-level transport tracing.

## Decision

eta-ai exposes effect wrappers:

    val with_chat_span :
      provider -> chat_request ->
      (response, ai_error) Eta.Effect.t ->
      (response, ai_error) Eta.Effect.t

    val with_stream_span :
      ?time_to_first_chunk_s:float ->
      provider -> chat_request ->
      ('a, ai_error) Eta.Effect.t ->
      ('a, ai_error) Eta.Effect.t

    val with_embeddings_span :
      provider -> Embedding.request ->
      (Embedding.response, ai_error) Eta.Effect.t ->
      (Embedding.response, ai_error) Eta.Effect.t

    val with_tool_span :
      ?tool_call_id:string ->
      ?tool_type:string ->
      tool_name:string ->
      ('a, ai_error) Eta.Effect.t ->
      ('a, ai_error) Eta.Effect.t

The wrappers use Eta.Effect.named_kind and Eta.Effect.annotate. They emit
string attributes from the A5 set:

- gen_ai.operation.name;
- gen_ai.provider.name;
- gen_ai.request.model;
- server.address;
- server.port;
- gen_ai.response.id;
- gen_ai.response.model;
- gen_ai.response.finish_reasons;
- gen_ai.usage.input_tokens;
- gen_ai.usage.output_tokens;
- gen_ai.request.stream;
- gen_ai.response.time_to_first_chunk;
- gen_ai.request.encoding_formats;
- gen_ai.tool.name;
- gen_ai.tool.call.id;
- gen_ai.tool.type;
- error.type on typed failures.

Sensitive prompt, output, tool argument, and tool result attributes are omitted
by default.

eta-ai also exposes suppress_provider_transport_observability as the default
policy for provider eta-http request subtrees.

## Rejected

- Capturing prompt/output/tool argument content by default. A5 marks those as
  opt-in content attributes.
- Adding a typed OTel attribute layer inside eta-ai. That belongs in Eta
  tracer/eta-otel if required later.
- Letting provider HTTP spans appear by default inside AI spans. That produces
  noisy nested transport spans and conflicts with the eta-otel recursion
  avoidance precedent.

## Consequences

- Provider packages can wrap their request effects without owning telemetry
  semantics.
- Transport-level debugging remains possible later as an explicit provider
  option.
- Response usage fields from providers become OTel usage attributes when
  available.
- Embeddings usage is read from the decoded embedding response, so provider
  runners cannot accidentally report telemetry that disagrees with the returned
  value.

## Evidence

- scratch/eta_ai_v1/probes/telemetry/attribute_set.md
- scratch/eta_ai_v1/probes/telemetry/verdict.md
- test/ai/core/test_eta_ai.ml
- lib/ai/audit/dep_usage.md
- lib/ai/audit/eta_escapes.md

## Verification

    bash lib/ai/audit/run.sh
    nix develop -c dune runtest lib/ai --force
    nix develop -c dune build
    nix develop -c eta-oxcaml-test-shipped
