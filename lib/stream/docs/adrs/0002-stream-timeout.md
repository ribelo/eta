# ADR: stream idle timeout

## Status

Accepted.

## Context

Eta_stream is pull-shaped: streams are interpreted by `fold_stream`, and each
consumer step asks the upstream for the next value. The original stream research
summary in `docs/research/evidence/stream_research/README.md` recorded the
same core shape: streams are pull-based, chunked, scoped by the surrounding Eta
runtime, and use Eta's typed effect channels.

Effect and ZIO both expose stream timeout as a pull-level idle timeout:

- Effect `Stream.timeout(duration)` is `timeoutOrElse` with an empty fallback.
  The timeout is checked for each pull, not for total stream lifetime.
- ZIO `ZStream.timeout(d)` wraps the stream's `toPull` function with an effect
  timeout. A pull that does not complete within `d` becomes clean stream end.

Eta needed the same user behavior after adding stream schedule/retry support:
line-oriented and network-style streams need a way to stop when the next value
stalls, while preserving typed failures and upstream cleanup.

## Decision

Add:

```ocaml
val timeout : Eta.Duration.t -> ('a, 'err) Stream.t -> ('a, 'err) Stream.t
```

`Stream.timeout d stream` is an idle timeout:

- the timeout is per next emitted value, not total stream lifetime;
- after each emitted value, the timeout resets for the next value;
- if the next value is not produced within `d`, the stream ends cleanly;
- upstream typed failures before the timeout are preserved;
- timeout cancels the active upstream pull/source, so cleanup runs.

Eta implements this with the stream interpreter it already owns:

1. run the upstream stream in a scoped child producer;
2. send upstream `Item`, `Done`, and `Failed` events through a bounded internal
   channel;
3. for each downstream pull, race receiving the next upstream event against
   `Effect.sleep d`;
4. on timeout, mark the producer stopped and cancel the scoped child.

This is not a copy of ZIO or Effect internals. It is the Eta equivalent of their
pull-timeout behavior, expressed through Eta's `fold_stream`, `Channel`, and
`Supervisor.scoped` machinery.

Zero duration ends without pulling. Eta `Duration` has no infinity value, so no
special infinite-duration branch is exposed.

## Why Not Use `Effect.timeout` Around The Whole Run?

Wrapping `run_collect stream` or a sink in `Effect.timeout` bounds total stream
runtime. That is not reference stream timeout behavior.

A stream that emits a value every 100 ms should continue under
`Stream.timeout 1s`; a total-runtime timeout would stop it after 1s. Conversely,
a stream that emits one value and then stalls should end only when the next pull
exceeds the idle duration.

## Alternatives Considered

- Add only `timeout_as`-style typed failure. Rejected for this slice because
  both reference `timeout` operators end the stream cleanly; failure/fallback
  variants can be added later as separate APIs.
- Implement timeout by materializing the stream or running the whole sink under
  `Effect.timeout`. Rejected because it changes semantics from per-pull idle
  timeout to total-runtime timeout and loses streaming behavior.
- Expose a public Pull/Channel API first. Rejected for this change because
  Eta_stream does not currently expose that abstraction; `fold_stream` already
  owns the necessary interpreter boundary.
- Use a raw Eio timeout. Rejected because stream timing must use Eta runtime
  sleep/clock so tests can drive it deterministically and behavior stays inside
  the effect runtime.

## Consequences

Positive:

- `Stream.timeout` matches the Effect/ZIO user contract closely.
- Timeout cleanup composes with `from_file`, `merge`, `flat_map_par`, and other
  scoped stream producers.
- Tests can use Eta's runtime clock instead of wall-clock sleeps.

Negative:

- The implementation needs a scoped producer and bounded channel because Eta has
  no public Pull abstraction to wrap directly.
- `timeout_or_else`, timeout-as-failure, and total lifetime timeout remain
  separate design decisions.

## References

- `docs/research/evidence/stream_research/README.md`
- `lib/stream/eta_stream.ml`
- `lib/stream/eta_stream.mli`
- `.reference/effect-smol/packages/effect/src/Stream.ts`
- `.reference/zio/streams/shared/src/main/scala/zio/stream/ZStream.scala`
