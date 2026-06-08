# A5 telemetry seam probe

Question: can eta-ai spans use Eta.Tracer while matching OpenTelemetry GenAI
semantic-convention attribute names?

Run:

    nix develop -c bash scratch/eta_ai_v1/probes/telemetry/run.sh

What the probe checks:

- chat inference span;
- streaming chat span with gen_ai.request.stream and
  gen_ai.response.time_to_first_chunk;
- embeddings span;
- tool-calling parent span plus execute_tool child span;
- required OTel GenAI attribute names from the semantic-conventions-genai
  repository.

Current result:

    telemetry_probe=ok
    spans=5
    semconv_source=semantic-conventions-genai/model/gen-ai/spans.yaml
    attribute_value_encoding=stringified_eta_attrs

Limit:

Eta.Tracer attributes are string pairs today. The probe validates names and
stringified values, matching eta-http's current observability precedent. Typed
OTel attribute values are a general Eta tracer/exporter concern, not an eta-ai
provider concern.
