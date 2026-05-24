# A3 schema matrix

Legend:

- supported-codec - eta-schema can decode/encode values of this shape.
- missing-export - eta-schema cannot emit provider JSON Schema for this shape.
- provider-required - provider APIs accept or require this JSON Schema keyword.
- out-of-scope - not needed for eta-ai v1 unless a provider fixture requires it.

| Concern | Provider requirement | eta-schema codec support | eta-schema JSON Schema export |
| --- | --- | --- | --- |
| string, bool, int, float | provider-required | supported-codec | missing-export |
| arrays | provider-required | supported-codec | missing-export |
| nested objects | provider-required | supported-codec through record builders | missing-export |
| required fields | provider-required | supported-codec through required fields | missing-export |
| optional fields | provider-required | supported-codec through optional fields | missing-export |
| enum | provider-required | supported-codec through Schema.enum | missing-export |
| tagged unions | useful for tool inputs and outputs | supported-codec through Schema.tagged_union | missing-export; likely oneOf/discriminator mapping needed |
| recursive schemas | useful but risky for provider strict modes | supported-codec through Schema.lazy_ | missing-export; requires $defs/$ref policy |
| oneOf | provider-required in OpenAI OpenAPI and common JSON Schema | no first-class JSON Schema vocabulary | missing-export |
| anyOf | provider-required for nullable/union shapes in OpenAI OpenAPI | no first-class JSON Schema vocabulary | missing-export |
| allOf | JSON Schema vocabulary, provider-dependent | no first-class JSON Schema vocabulary | missing-export |
| $ref | required for reusable and recursive JSON Schema | no first-class JSON Schema vocabulary | missing-export |
| additionalProperties | provider-required for arbitrary object schemas | no first-class JSON Schema vocabulary | missing-export |

Verdict:

eta-schema can validate application values but cannot currently produce
provider-ready JSON Schema. A3 falsifies eta-schema integration for eta-ai v1
unless a JSON Schema export module lands before Phase A-C.
