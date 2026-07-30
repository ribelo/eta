# ADR 0012: OpenAI Realtime Protocol Split

Status: accepted.

## Context

`Eta_ai_openai.Realtime` modelled a single conversational speech-to-speech
protocol. OpenAI publishes three distinct live audio protocols that share only a
WebSocket substrate:

- conversation sessions on `/v1/realtime`, with an assistant response lifecycle;
- transcription sessions on `/v1/realtime` with `session.type = "transcription"`,
  which produce transcript deltas and completions and no assistant turn;
- translation sessions on `/v1/realtime/translations`, which stream continuously
  from incoming audio, never accept `response.create`, use `session.`-prefixed
  events, and terminate through an explicit `session.close` to `session.closed`
  drain fence.

Their session configuration, event vocabulary, and completion semantics differ.
Only framing, scoped ownership, send serialization, event pulling, cancellation,
and release are genuinely common.

## Decision

`Eta_ai_openai.Realtime` exposes `Conversation`, `Transcription`, and
`Translation` as explicit sibling protocol modules. The existing conversational
surface moves under `Realtime.Conversation` with no alias left behind. Each
protocol owns its own session, client-event, server-event, codec-error, and
nominal error types, and decodes every documented audio-relevant event while
preserving unknown events with their type and complete JSON.

`eta_ai_openai_realtime_eio` exposes three distinct abstract connection types
backed by one private WebSocket engine, so a client event for one protocol cannot
be sent through another protocol's connection. Each connection serializes sends,
delivers events by pull, and exposes two terminations: `finish`, which performs
the protocol's graceful drain and keeps delivering events until the terminal
event arrives or the effect is cancelled, and `abort`, which terminates
immediately. A bounded-wait convenience wraps `finish` with a caller-supplied
timeout rather than hiding a default one.

The transport rejects deterministic local misuse: an event a connection's
protocol does not define, appending after finish, finishing twice, sending after
abort, and concurrent reads. Server-owned session policy is submitted to OpenAI
rather than predicted locally.

## Rejected

- One session and event union across the three protocols. This weakens
  exhaustivity and lets translation events appear in a conversation match.
- One connection type carrying a runtime protocol tag. This moves a static
  distinction into runtime checks.
- A single `close` that silently chooses drain or termination. Graceful
  completion can block and can emit valuable final output, so callers must choose
  it explicitly.
- A hidden default `finish` timeout. Timeout policy belongs to the caller.
- Three independent WebSocket implementations. Framing, cancellation, and release
  are Eta transport invariants and must not be reimplemented per protocol.
- A fully indexed type-state connection API. Server transitions arrive
  asynchronously, so exhaustive type-state would obstruct ordinary use without
  removing the need for runtime rejection.

## Consequences

- Callers cannot confuse the three protocols, and each event match is exhaustive
  over one real protocol.
- Translation's drain fence is expressible, so final translated audio is not
  dropped by an eager close.
- Existing conversational Realtime callers are updated in the same change.
- Lifecycle tests run once against all three connections while protocol
  state-machine tests remain separate.

## Evidence

- `docs/requirements/eta-ai-openai-audio/realtime-architecture.md`
- `docs/requirements/eta-ai-openai-audio/realtime-transcription.md`
- `docs/requirements/eta-ai-openai-audio/realtime-translation.md`
- `docs/requirements/eta-ai-openai-audio/streaming-lifecycle.md`
- ADR 0007 for the provider-neutral Realtime lifecycle interface.
