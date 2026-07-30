---
kind: requirement
---
# Eta AI module organization

## Intent

Keep application vocabulary and provider-authoring machinery discoverable at
distinct, coherent module seams.

## Requirements

- The `Eta_ai` public module shall expose `Json` as its JSON value and projection module. ^aimod-obwo
- The `Eta_ai` public module shall expose `Responses`, `Embedding`, `Image`, `Speech`, `Transcription`, `Rerank`, `Video`, and `Realtime` as capability modules. ^aimod-9elo
- The `Eta_ai` public module shall expose `Stream` and `Toolkit` as lifecycle-owning modules. ^aimod-wnrz
- The `Eta_ai.Provider` module shall expose `Codec`, `Transport`, and `Telemetry` as provider-authoring modules. ^aimod-zmbl
- The `Eta_ai.Provider.Codec` module shall own provider-error-aware JSON decoding support. ^aimod-72y8
- The `Eta_ai.Provider.Transport` module shall own shared provider HTTP request construction and execution. ^aimod-s0tf
- The `Eta_ai.Provider.Telemetry` module shall own shared provider inference, embedding, and tool telemetry. ^aimod-mhgx
- The `Eta_ai` public module shall expose provider-authoring operations through the applicable `Provider` child module rather than duplicating those operations at the top level. ^aimod-cb26
- Each public `Eta_ai` child module shall be backed by a separate implementation and interface compilation unit and re-exported through `Eta_ai`. ^aimod-iqxv
- The `Eta_ai` public module shall expose its common content, message, prompt, response, tool, and chat-request vocabulary at the top level. ^aimod-dtbe
- Eta AI provider codecs shall obtain blank checking, trimming, and trimmed comparison from `Eta.String_helpers` rather than through `Eta_ai.Provider.Codec`. ^aimod-tdpl
- The `Eta_ai.Provider.Transport` interface shall expose a non-overlapping set of provider HTTP primitives rather than preserving overlapping legacy builders and runners. ^aimod-smby
- The `Eta_ai.Provider.Transport` interface shall expose GET and JSON request construction together with decoded JSON, binary, and streaming execution. ^aimod-fnni
- The `Eta_ai.Stream` module shall preserve the current SSE stream lifecycle interface when it moves from the `Eta_ai` top level. ^aimod-ez2q
- The `Eta_ai.Toolkit` module shall preserve the current ordered tool-registry interface when it moves from the `Eta_ai` top level. ^aimod-ip7g
