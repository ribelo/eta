# A5 verdict

Status: accepted.

Decision:

- eta-ai can use Eta.Tracer for chat, streaming chat, embeddings, and tool
  execution spans.
- OTel GenAI semantic-convention attribute names have a clean v1 mapping.
- Sensitive content attributes must be opt-in only.
- HTTP calls made by providers should use eta-http with observability disabled
  inside the AI span, following the eta-otel suppression precedent.

Evidence:

- OpenTelemetry semantic-conventions-genai defines inference, embeddings, and
  execute_tool spans.
- Required names map directly to eta-ai provider requests:
  gen_ai.operation.name, gen_ai.provider.name, gen_ai.request.model,
  server.address, and server.port.
- Streaming has explicit gen_ai.request.stream and
  gen_ai.response.time_to_first_chunk attributes.
- Usage fields from A4 map to gen_ai.usage.input_tokens and
  gen_ai.usage.output_tokens.
- Tool-calling maps to a parent inference span and an internal execute_tool
  child span with gen_ai.tool.* attributes.

Verification:

    nix develop -c bash .scratch/research/evidence/eta_ai_v1/probes/telemetry/run.sh

Expected output:

    telemetry_probe=ok
    spans=5
    attribute_value_encoding=stringified_eta_attrs

Disproof signature outcome:

- Not triggered for attribute names. The OTel GenAI conventions cover the v1 AI
  operations directly.
- Eta.Tracer only stores string attributes today. A5 accepts stringified values
  for v1 because eta-http already follows that precedent. If typed OTel
  attributes become required, that should be handled as a general Eta
  tracer/eta-otel extension, not inside eta-ai.

Phase A-C implication:

- AC6 should use the attribute set in attribute_set.md.
- Provider HTTP transport spans should be suppressed to avoid nested HTTP noise
  unless the caller explicitly opts into low-level transport tracing.
