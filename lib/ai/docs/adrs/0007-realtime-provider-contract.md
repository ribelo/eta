# ADR 0007: Provider-Neutral Realtime Lifecycle

Status: accepted.

## Context

OpenAI and xAI Realtime use the same broad WebSocket lifecycle but differ in
session configuration, credentials, binary transport, conversation events, and
provider extensions. xAI streaming speech-to-text, streaming text-to-speech,
and Responses WebSocket mode use separate protocols despite sharing the same
WebSocket substrate.

Eta already centralizes RFC 6455 transport in `Eta_http_eio.Ws.Client`. The
remaining repeated concern is the scoped typed connection lifecycle, not a
unified provider event union.

## Decision

Eta AI exposes a provider-neutral Realtime codec and transport interface with
provider-specific session, client-event, server-event, and error types.

OpenAI and xAI retain separate lossless protocol algebras behind that interface.
Eio adapters share scoped connection, serialized send, pull-event, close,
cancellation, and release behavior.

Responses WebSocket, streaming speech-to-text, and streaming text-to-speech
remain distinct public protocols. They may reuse private transport machinery but
do not implement the conversational Realtime interface.

## Rejected

- Expanding `Eta_ai_openai.Realtime` into an xAI superset. Provider-only fields
  would become misleading options for OpenAI callers.
- One union of all Realtime events. This weakens provider-specific exhaustivity.
- Treating all audio WebSockets as Realtime. Their framing and completion
  semantics differ.
- Leaving lifecycle cleanup to each provider adapter. Close and cancellation
  ownership are Eta transport invariants.

## Consequences

- Provider codecs remain complete and strongly typed.
- Shared lifecycle tests can run against OpenAI and xAI Eio transports.
- Binary messages are provider-defined behavior rather than unconditional
  protocol errors.
- Applications continue to own conversation and tool-execution state.

## Evidence

- `docs/requirements/eta-ai-xai/shared-realtime.md`
- `docs/requirements/eta-ai-xai/realtime-speech.md`
- `.scratch/research/xai/voice-apis-first-party-2026-07-29.md`
- `lib/ai/openai/realtime.ml`
- `lib/ai/openai_realtime_eio/eta_ai_openai_realtime_eio.ml`
