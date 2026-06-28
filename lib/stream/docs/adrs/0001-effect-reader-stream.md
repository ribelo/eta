# ADR: effect-reader stream source

## Status

Proposed.

## Context

Eta_stream currently supports finite in-memory streams, files, mailboxes, Eio
streams, merge, and parallel flat-map. It does not expose a public constructor
for an owned effectful pull source with a finalizer.

eta-ai A2 needs to parse SSE events from eta-http Body.Stream. The parser can
read chunks and discard the body correctly when used directly, but eta-ai wants
to expose parsed events as Eta_stream.Stream so callers can compose with take,
map, grouped, merge, and sinks.

The missing invariant is ownership: if downstream stops early, fails, or is
interrupted, the upstream HTTP body must be discarded exactly once. For h1 this
returns the connection checkout. For h2 this releases the stream permit and may
queue RST_STREAM for active streams.

## Decision

Add a public Eta_stream.Stream source constructor for effectful pull readers
with finalization. The exact name can still change, but the required shape is:

    val from_effect_reader :
      ?name:string ->
      read:(unit -> ('a option, 'err) Eta.Effect.t) ->
      release:(unit -> (unit, 'err) Eta.Effect.t) ->
      unit ->
      ('a, 'err) Eta_stream.t

Required behavior:

- read returns Some value for an emitted item and None for EOF.
- release runs exactly once on EOF, downstream stop, downstream failure, and
  interruption.
- downstream take n must stop pulling after n values and run release.
- release errors stay in the stream error channel.
- the source should not allocate an unbounded mailbox or producer fiber.

An acquire/read/release variant may be better if future sources need to acquire
the resource when the stream is run:

    val unfold_resource :
      ?name:string ->
      acquire:('resource, 'err) Eta.Effect.t ->
      read:('resource -> ('a option, 'err) Eta.Effect.t) ->
      release:('resource -> (unit, 'err) Eta.Effect.t) ->
      ('a, 'err) Eta_stream.t

## Alternatives Considered

- Use Eta_stream.Mailbox.to_stream with a producer fiber. Rejected for eta-ai
  public streaming because downstream cancellation does not own or stop the
  producer by construction.
- Use Eta_stream.Stream.from_eio_stream. Rejected because the source has no
  end-of-stream marker and no finalizer.
- Parse the entire SSE response into a list and call from_iterable. Rejected
  because it loses streaming, back-pressure, and bounded-memory behavior.
- Hide a custom eta-ai stream type. Rejected because this is a general stream
  source ownership problem, not an AI-specific domain concept.

## Consequences

Positive:

- eta-ai can expose provider streams as Eta_stream.Stream without leaking HTTP
  bodies on early stop.
- Other libraries can wrap pull APIs, cursors, and decoder loops without
  ad-hoc mailbox producers.
- The source ownership rule lives in eta-stream, where Eta_stream.take already owns
  downstream stop semantics.

Negative:

- Eta_stream gains one more primitive constructor and must test EOF, failure,
  downstream stop, and interruption release paths.
- The API must decide whether finalizer errors are emitted, suppressed under a
  primary failure, or reported as suppressed causes.

## Rollout / Migration

- Add focused eta-stream tests before using the constructor from eta-ai.
- Port the A2 SSE parser from direct Body.Stream reads to the new stream source.
- Keep eta-ai provider packages from exposing streaming APIs until this
  primitive lands or the objective explicitly accepts a different public shape.

## References

- docs/research/evidence/eta_ai_v1/probes/streaming_sse/
- docs/research/evidence/eta_ai_v1/probes/streaming_sse/verdict.md
- lib/http/body/stream.mli
- lib/stream/eta_stream.mli
