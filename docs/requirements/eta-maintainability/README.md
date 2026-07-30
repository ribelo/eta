# Eta maintainability requirements

This directory indexes desired-state requirements for shared Eta implementation
seams whose consistency is itself an acceptance obligation.

## Capability notes

- [[ai-module-organization]] — the eta-ai public namespace and provider-authoring
  modules.
- [[ai-json]] — the Yojson-backed provider-codec projection surface.
- [[ai-telemetry]] — shared, typed inference telemetry.
- [[provider-errors]] — lossless first-class provider failures and neutral
  projection.
- [[ai-wire-sharing]] — shared OpenAI-compatible and xAI provider plumbing.
- [[http-multipart]] — one injection-safe multipart encoder.
- [[url-query-encoding]] — one query-component percent encoder.
- [[http-redaction]] — one URI-redaction implementation.
- [[http-server-invariants]] — shared H1/H2 lifecycle invariants without a
  shared protocol state machine.
- [[benchmark-support]] — shared benchmark and AI fixture support.

## Proposed verification seams

These are planning notes, not requirements:

- Use public-signature census tests for eta-ai namespace ownership.
- Use static dependency and symbol checks to reject reintroduced provider-local
  implementations of shared wire helpers.
- Exercise multipart injection rejection, byte preservation, and boundary
  collision handling with deterministic fixtures.
- Exercise percent encoding over every ASCII octet and representative UTF-8
  byte sequences.
- Run the existing H1 and H2 lifecycle suites against extracted common helpers.
- Keep benchmark/test helper checks outside published package surfaces.
