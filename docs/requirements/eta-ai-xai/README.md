# Eta xAI provider requirements

This directory indexes the desired-state capability requirements for the xAI
provider.

## Capability notes

- [[package-boundary]] — opam packages, Dune public libraries, OCaml modules,
  and dependency boundaries.
- [[public-surface]] — callable xAI product boundary.
- [[errors]] — lossless provider failures and neutral projection.
- [[capabilities]] — provider feature discovery.
- [[validation]] — local validation and dynamic server policy.
- [[pagination]] — explicit page ownership.
- [[observability]] — GenAI spans, session spans, suppression, and content
  exclusion.
- [[security]] — redacted inference, management, and ephemeral credentials.
- [[responses]] — Responses requests, outputs, tools, lifecycle, and streaming.
- [[files]] — inference-side file resources.
- [[collections]] — collection management and document search.
- [[models]] — model catalog discovery.
- [[speech-to-text]] — unary and streaming transcription.
- [[text-to-speech]] — unary and streaming synthesis.
- [[realtime-speech]] — realtime speech-to-speech sessions.
- [[voices]] — built-in and read-only custom-voice discovery.
- [[shared-realtime]] — provider-neutral Realtime codec and transport contract.

## Proposed verification seams

These are planning notes, not requirements:

- Keep public-signature and package-census checks linked to the requirement IDs
  that define package and surface boundaries.
- Use request, response, error, pagination, and unknown-variant fixtures for
  transport-neutral codecs.
- Exercise multipart ordering and each REST method/path with a recording client.
- Run shared lifecycle tests against each Eio WebSocket protocol, including
  framing, serialization, cancellation, closure, and unknown events.
- Inspect emitted spans and nested transport activity with secret and content
  sentinels.
- Reserve authenticated canaries for provider facts that offline contracts
  cannot establish.
