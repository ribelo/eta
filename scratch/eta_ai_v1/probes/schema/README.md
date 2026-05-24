# A3 schema integration probe

Question: can eta-schema provide provider-ready JSON Schema for eta-ai tool
arguments and structured output?

Run:

    nix develop -c bash scratch/eta_ai_v1/probes/schema/run.sh

What the probe checks:

- Provider docs require JSON Schema objects for OpenAI function parameters,
  OpenAI structured outputs, and Anthropic tool input_schema.
- eta-schema still passes its codec tests for enums, records, tagged unions,
  transforms, and recursive schemas.
- eta-schema does not expose a JSON Schema exporter or JSON Schema vocabulary
  constructors such as oneOf, anyOf, allOf, $ref, or additionalProperties.

Current result:

    schema_probe=gap
    eta_schema_tests=ok
    provider_schema_docs=ok
    eta_schema_json_schema_export=missing

The gap is filed as
packages/eta-schema/docs/adrs/0001-json-schema-export.md. eta-ai v1 should use
raw JSON tool schemas unless that eta-schema extension lands first.
