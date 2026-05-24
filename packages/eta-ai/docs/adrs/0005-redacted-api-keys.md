# ADR 0005: Redacted API Keys

Status: accepted.

## Context

Provider packages need API keys to build HTTP Authorization headers. AC6
requires those keys to travel as Eta_redacted.t and not leak through eta-ai
logs or traces. Eta keeps Eta.Redacted as a compatibility alias, but eta-ai
depends on the standalone eta-redacted package directly.

Eta_redacted.t deliberately allows explicit value extraction at an IO boundary.
That is required for constructing provider headers. The safety boundary is that
the key is not a string in ordinary eta-ai APIs and its formatter prints a
redacted marker.

## Decision

eta-ai exposes:

    type api_key = string Eta_redacted.t
    val api_key : string -> api_key

The constructor labels keys as api_key, so Eta_redacted.pp renders
<redacted:api_key>.

Provider auth builders accept api_key. They may call Eta_redacted.value only at
the HTTP header boundary. eta-ai telemetry wrappers do not inspect headers and
do not emit prompt, output, tool argument, tool result, or API-key attributes.

Provider transport subtrees should be wrapped in
suppress_provider_transport_observability by default, so transport logs and
spans do not leak headers inside AI spans.

## Rejected

- Passing API keys as plain strings through eta-ai public APIs.
- Logging provider headers from eta-ai core.
- Hiding value extraction entirely. Provider packages still need the raw key at
  the HTTP auth boundary.

## Evidence

- packages/eta-ai/test/test_eta_ai.ml
- packages/eta-ai/test/negative/print_api_key_negative.ml
- packages/eta-ai/test/negative/run.sh

## Verification

    nix develop -c dune runtest packages/eta-ai --force

The negative fixture must fail to compile:

    let key : Eta_ai.api_key = Eta_ai.api_key "sk-test-negative" in
    print_endline key

Expected compiler shape:

    This expression has type Eta_ai.api_key = string Eta_redacted.t
    but an expression was expected of type string
