# ADR 0003: Raw JSON Toolkits

Status: accepted.

## Context

AC4 needs a composable tool registry for provider requests. OpenAI and
Anthropic both require tool schemas as JSON Eta_schema documents.

A3 found that eta-schema can decode and encode application values, but it
cannot emit provider-ready JSON Eta_schema. It has no public exporter for required
provider vocabulary such as oneOf, anyOf, allOf, $ref, or
additionalProperties.

## Decision

eta-ai v1 toolkits store caller-supplied raw JSON schemas:

    type toolkit

    val make_tool :
      ?description:string ->
      ?strict:bool ->
      name:string ->
      input_schema_json:raw_json ->
      unit ->
      (tool, ai_error) result

    val add_tool : tool -> toolkit -> (toolkit, ai_error) result

The toolkit checks only eta-ai registry invariants:

- tool names are non-empty;
- input_schema_json is non-empty;
- duplicate tool names are rejected;
- registration order is preserved.

It does not parse or validate JSON Eta_schema. Provider packages pass the raw schema
through to their request encoders.

## Rejected

- eta-ai-local JSON Eta_schema generation. That would duplicate eta-schema work and
  create a second schema language.
- Depending on eta-schema in eta-ai v1. A3 falsified that integration until
  eta-schema grows JSON Eta_schema export.
- Silent duplicate names. Provider APIs key tool calls by name, so duplicate
  registration is an application error.

## Consequences

- Tool registration is pipe-friendly through add_tool.
- Provider packages can share the common toolkit representation.
- Applications that need local argument validation must validate outside
  eta-ai v1 or wait for eta-schema JSON Eta_schema export.

## Evidence

- scratch/eta_ai_v1/probes/schema/verdict.md
- lib/schema/docs/adrs/0001-json-schema-export.md
- test/ai/core/test_eta_ai.ml

## Verification

    bash lib/ai/audit/run.sh
    nix develop -c dune runtest lib/ai --force
    nix develop -c dune build
    nix develop -c eta-oxcaml-test-shipped
