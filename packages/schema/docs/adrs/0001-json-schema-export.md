# ADR: JSON Schema export module

## Status

Proposed.

## Context

eta-schema currently owns runtime codecs: decode JSON, encode values, validate
with refinements, and preserve structured issues. It intentionally does not
ship JSON Schema generation.

eta-ai provider APIs require JSON Schema objects for tool argument schemas and
structured outputs:

- OpenAI function parameters are described as a JSON Schema object.
- OpenAI structured outputs accept a json_schema.schema object.
- Anthropic tool input_schema is documented as JSON schema draft 2020-12.

The existing Schema.t value is not enough at the provider boundary because
providers need a JSON Schema document, not only an OCaml decoder.

## Decision

Add a separate JSON Schema export module to eta-schema before eta-ai depends on
typed eta-schema tool schemas.

Required capabilities:

- choose and document the supported JSON Schema draft;
- export primitive types, arrays, records, required fields, optional fields,
  enums, and nested objects;
- support oneOf, anyOf, allOf, $defs, $ref, and additionalProperties;
- define how Schema.tagged_union maps to provider-safe oneOf or anyOf shapes;
- define recursion policy for Schema.lazy_;
- preserve descriptions or annotations if eta-schema adds them later;
- include validator tests for generated schemas.

The eta-ai v1 fallback is raw JSON schemas supplied by the caller.

## Alternatives Considered

- Generate a small eta-ai-only subset. Rejected because JSON Schema export is a
  schema concern and would create a second schema language.
- Treat eta-schema runtime decoders as proof of provider schema support.
  Rejected because providers never see those decoders.
- Block all eta-ai tool use until eta-schema export lands. Rejected for v1
  because raw JSON schemas preserve provider capability without pretending the
  typed integration is solved.

## Consequences

Positive:

- eta-ai can ship tool calling with raw JSON while keeping typed schemas honest.
- eta-schema can add JSON Schema generation once, with validator tests and draft
  semantics, instead of provider packages inventing local emitters.

Negative:

- eta-ai v1 users do not get typed tool-schema generation from eta-schema unless
  the exporter lands before Phase A-C.
- The future exporter needs careful compatibility tests because OpenAI strict
  mode only supports a subset of JSON Schema.

## Rollout / Migration

- Keep eta-ai AC3 raw-JSON capable.
- Add eta-schema JSON Schema export as its own package slice.
- Once the exporter exists, add eta-ai adapters from Schema.t to provider tool
  schemas and structured-output schemas.

## References

- scratch/eta_ai_v1/probes/schema/
- packages/eta-schema/README.md
- packages/eta-schema/eta_schema.mli
