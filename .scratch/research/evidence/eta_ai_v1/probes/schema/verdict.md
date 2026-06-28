# A3 verdict

Status: falsified for eta-schema integration in eta-ai v1.

Decision:

- eta-ai v1 should accept raw JSON tool schemas unless eta-schema gains a JSON
  Schema export module before Phase A-C closes.
- Do not build an eta-ai-local JSON Schema generator around eta-schema internals.
- The required eta-schema extension is filed as
  `lib/schema/docs/adrs/0001-json-schema-export.md`.

Evidence:

- OpenAI FunctionParameters are described as a JSON Schema object and allow
  additionalProperties. OpenAI structured outputs also take a JSON Schema object.
- Anthropic tools require input_schema and document it as JSON schema draft
  2020-12 for the tool input shape.
- eta-schema supports runtime codecs for nested records, enums, tagged unions,
  transforms, and recursive schemas. The package tests still pass.
- eta-schema README explicitly says Schema.json_schema is not exposed and JSON
  Schema generation should be a separate module with a chosen draft, real $ref
  handling, and validator tests.
- eta_schema.mli has no JSON Schema exporter and no public constructors for
  oneOf, anyOf, allOf, $ref, or additionalProperties.

Verification:

    nix develop -c bash .scratch/research/evidence/eta_ai_v1/probes/schema/run.sh

Expected output:

    schema_probe=gap
    eta_schema_tests=ok
    provider_schema_docs=ok
    eta_schema_json_schema_export=missing

Disproof signature outcome:

- Triggered. eta-schema cannot currently represent provider-required JSON
  Schema output. It can represent corresponding OCaml values for local
  decode/encode, but that is not enough for provider tool schemas.

Phase A-C implication:

- AC3 should model tool schemas as raw JSON for v1 unless the eta-schema
  exporter lands first.
- A future eta-schema exporter must choose a JSON Schema draft, define $defs and
  $ref behavior, map tagged unions to oneOf/anyOf, support
  additionalProperties, and run validator tests against provider fixtures.
