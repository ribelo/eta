# ADR 0013: Audio Stream Ownership

Status: accepted.

## Context

OpenAI audio introduces several streaming shapes that are not interchangeable:
raw chunked speech audio, Speech server-sent events, streamed file-transcription
events, and live Realtime event streams. Audio streams are also long-lived and
large, so a policy tuned for bounded JSON responses is wrong for them.

Returning a naked `Eta_http.Body.Stream.t` would leak transport errors past the
provider's nominal error channel and put body release in the caller's hands.
Copying chunks into an unbounded queue would discard backpressure. Callback
delivery would keep body ownership inside the runner while the caller is still
consuming.

Eta already owns the equivalent invariants for SSE inference streams in
ADR 0002 and for Realtime lifecycles in ADR 0007.

## Decision

Every OpenAI audio stream is a provider-owned abstract pull stream, distinct per
protocol: raw speech audio, Speech events, transcription events, and each
Realtime protocol's events are separate types. Transport failures map into
`Eta_ai_openai.Error.t`. Normal completion, failure, and cancellation each
release the underlying body or connection exactly once, and when cleanup itself
fails the triggering provider or transport failure remains the primary cause.

A pull stream has one owner. A second concurrent operation on the same stream
fails immediately with a nominal concurrent-use error rather than being
serialized behind an implicit lock, because silent serialization hides a protocol
misuse that the caller should fix. Outbound Realtime sends are serialized,
because interleaved frames would corrupt the wire rather than merely reorder
caller intent.

Streams bound their unframed buffer size, decoded JSON size, and pending decoded
event count by default, and accept per-operation overrides. They deliberately
impose no default limit on total streamed audio: long calls, dictations, and
translation sessions are legitimate, and the parser-state bounds are what protect
memory.

Collection of a stream into a single value is an explicit convenience that
accepts a caller-supplied maximum byte limit, never an implicit default applied
to a streaming API.

## Rejected

- Return `Eta_http.Body.Stream.t` directly. This leaks transport errors and body
  ownership across the provider boundary.
- Buffer chunks into an unbounded queue or `Eta_stream` value. This discards
  backpressure and, for audio, unbounded memory follows immediately.
- Serialize concurrent stream operations internally. This conceals misuse and
  makes ordering depend on scheduling.
- Fixed non-configurable bounds. Different audio formats and event schemas need
  different framing headroom.
- A default total-audio cap. It would break the primary use cases at an
  arbitrary threshold.

## Consequences

- Audio streaming failures stay in one nominal error vocabulary with complete
  provider facts.
- Cancellation and early stop release transport exactly once, and diagnostics
  from a failing cleanup never mask the real cause.
- Callers must consume a stream from one place, which is checkable in tests.
- Long-running audio works by default while malformed or hostile framing is
  still bounded.

## Evidence

- `docs/requirements/eta-ai-openai-audio/streaming-lifecycle.md`
- `docs/requirements/eta-ai-openai-audio/speech-generation.md`
- `docs/requirements/eta-ai-openai-audio/file-transcription.md`
- ADR 0002 for the original SSE pull-stream ownership decision.
