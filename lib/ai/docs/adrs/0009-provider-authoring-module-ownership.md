# ADR 0009: Eta AI Provider-Authoring Module Ownership

Status: accepted.

## Context

`Eta_ai` accumulated application vocabulary, provider codec helpers, HTTP
execution, stream lifecycle, tool registries, and telemetry in one public
interface. Adding provider-neutral Responses and Realtime contracts pushed that
interface past a useful navigation boundary. Splitting records into many shallow
modules would reduce file size without giving callers a clearer seam.

## Decision

Keep common content, message, prompt, response, tool, and chat-request vocabulary
at the `Eta_ai` top level. Expose capability vocabulary through `Json`,
`Responses`, `Embedding`, `Image`, `Speech`, `Transcription`, `Rerank`, `Video`,
and `Realtime`. Expose lifecycle-owning `Stream` and `Toolkit` modules.

Provider-authoring behavior lives under `Eta_ai.Provider`:

- `Provider.Codec` owns provider-error-aware JSON decoding support;
- `Provider.Transport` owns shared HTTP request construction and execution;
- `Provider.Telemetry` owns typed inference, embedding, tool, and ordinary
  provider-client telemetry.

`Provider.Codec` does not re-export generic string normalization; callers use
`Eta.String_helpers` directly. `Provider.Telemetry` accepts a typed error view
containing classification and formatting functions as public provider-authoring
vocabulary, so providers retain their actual effect error type while sharing
span policy. Ordinary operation names are provider-owned non-empty strings.

Ordinary provider client spans use `eta_ai.provider.name`,
`eta_ai.operation.name`, server authority attributes, and `error.type`. They
suppress nested eta-http observability. Speech-to-text, text-to-speech, voice
resources, catalogs, and resource-management calls use ordinary provider spans
unless the accepted GenAI convention defines their operation semantics.

Each public child module is backed by its own `.ml` and `.mli` compilation unit
and re-exported through `Eta_ai`. The old top-level provider-authoring operations
are deleted and all callers move to the owning child module; no compatibility
aliases remain.

`Provider.Transport` is deepened during that breaking move instead of preserving
overlapping builders and runners. Its provider-neutral surface is limited to
GET and JSON request construction plus decoded JSON, binary, and streaming
execution. Capability operations remain in capability/provider modules.
`Stream` and `Toolkit` retain their already-cohesive lifecycle and ordered
registry interfaces when moved.

## Rejected

- Keep one flat `Eta_ai` interface. This mixes application and adapter concerns
  and makes ownership harder to discover.
- Move all common vocabulary under `Chat`. Responses projects into the same
  vocabulary, so that name would assert a false ownership boundary.
- Split every record into its own module. That would distribute declarations
  without creating deeper interfaces.

## Consequences

- Provider packages have one discoverable authoring namespace.
- Application-facing vocabulary remains concise at existing call sites.
- The change is intentionally breaking; provider callers are updated directly.
- Installed-interface verification must reject leaked private compilation-unit
  paths.
