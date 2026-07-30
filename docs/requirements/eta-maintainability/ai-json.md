---
kind: requirement
---
# Eta AI JSON projections

## Intent

Provide one small, exception-free Yojson projection surface for Eta AI provider
codecs without creating another JSON representation or package.

## Requirements

- The `Eta_ai.Json.t` type shall be `Yojson.Safe.t`. ^aijson-ovea
- If Yojson rejects input text as invalid JSON, then `Eta_ai.Json.parse` shall return an error result. ^aijson-uy4a
- When `Eta_ai.Json.object_` receives a field whose value is absent, `Eta_ai.Json.object_` shall omit that field from the resulting object. ^aijson-f503
- When a named object member is a JSON boolean, `Eta_ai.Json.bool_member` shall return that boolean. ^aijson-en3p
- When a named object member is a finite JSON number representable as an OCaml float, `Eta_ai.Json.float_member` shall return that number as a float. ^aijson-q32v
- The Eta package set shall keep `Eta_ai.Json`, the dependency-free `Eta_schema.Json`, the `Eta_schema_yojson` adapter, and HTTP JSON response construction as distinct surfaces. ^aijson-y9w5
