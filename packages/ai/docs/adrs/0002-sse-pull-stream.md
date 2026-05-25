# ADR 0002: SSE Pull Stream

Status: accepted.

## Context

AC3 needs eta-ai to consume provider SSE responses from eta-http body streams.
A2 proved eta-http Body.Stream can supply bounded chunks, EOF, and explicit
discard. A2 also found that eta-stream is missing a public effect-reader source
that owns upstream finalization under EOF, downstream stop, downstream failure,
and interruption.

The AC3 implementation must therefore parse SSE and release eta-http bodies
without presenting the result as an eta-stream value.

## Decision

eta-ai exposes an abstract pull parser:

    type stream

    val stream_of_body :
      ?max_buffer_bytes:int -> provider -> Http.Body.Stream.t -> stream

    val read_stream_event :
      stream -> (stream_event option, ai_error) Eta.Effect.t

    val read_stream_events :
      ?max_events:int -> stream -> (stream_event list, ai_error) Eta.Effect.t

    val close_stream : stream -> (unit, ai_error) Eta.Effect.t

The parser owns only SSE framing and eta-http body release. Provider-specific
JSON stays inside provider.decode_stream_event.

The unframed SSE buffer is bounded by max_buffer_bytes, defaulting to 1 MiB.
Calling read_stream_events with max_events discards the body when the limit is
reached, which covers early-stop callers.

## Rejected

- Exposing Stream.Stream now. eta-stream does not yet have the required
  owned source primitive.
- Parsing the whole response through read_all before decoding. That loses
  early-stop release and bounded streaming behavior.
- Moving provider JSON parsing into the SSE layer. A1 says provider envelopes
  are structurally different and belong in provider-local decoders.

## Consequences

- AC3 can handle partial chunks, named events, tool-call deltas, error events,
  done markers, EOF, and early body discard.
- Provider packages can implement decode_stream_event without owning eta-http
  transport state.
- A later eta-stream source primitive can wrap the same event reader instead
  of replacing provider decoders.

## Evidence

- scratch/eta_ai_v1/probes/streaming_sse/verdict.md
- packages/eta-ai/test/test_eta_ai.ml
- packages/eta-ai/audit/dep_usage.md
- packages/eta-ai/audit/eta_escapes.md

## Verification

    bash packages/eta-ai/audit/run.sh
    nix develop -c dune runtest packages/eta-ai --force
    nix develop -c dune build
    nix develop -c eta-oxcaml-test-shipped
