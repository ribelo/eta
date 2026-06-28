# ADR: stream core shape — add a public typed-transducer surface

## Status

Proposed. Supersedes the pre-rename stream design verdict recorded in
`docs/research/journal.md` (V-S1, V-S6) based on the executable evidence in
`docs/research/evidence/stream-core-reopen/verdict.md`.

This ADR records the decision. Implementation is a separate follow-up
objective; this pass ships research only.

## Context

The original `eta_stream` shape decision (V-S1..V-S10) chose:

- public `Stream.t` (chunked pull, single `'err` row);
- public fold `Sink.t`;
- Channel kept internal;
- the claim that a public Channel would "import seven parameters into OCaml
  APIs".

Two facts have changed since:

1. **The V-S6 revisit trigger has fired in production.** `lib/http/body/Stream.ml`
   is a *separate* hand-rolled pull type with `of_reader ~release read_fn` and
   terminal signals `Chunk | Last | End`. `lib/http/body/transducer.ml`
   implements gzip decode/encode as a stateful reader carrying leftover
   (`Gz.Inf.src_rem`), terminal decoder state, and a release finalizer. It does
   **not** use `eta_stream`. The package whose stated job is streaming could not
   host its own HTTP body transducer.

2. **The "seven parameters" claim is not supported by OCaml inference.**
   Effect-TS/Scala carry 7 parameters (`OutElem, OutErr, OutDone, InElem,
   InErr, InDone, Env`). In Eta-shaped OCaml the count is **5**: Eta has one
   typed-error row so `OutErr`/`InErr` collapse to one `'err`, and `Env` is
   absorbed into the embedded `('a,'err) Effect.t`. Call sites infer with zero
   annotations; the result is recorded in
   `docs/research/evidence/stream-core-reopen/verdict.md`.

The current shape provably **cannot** express a streaming transducer: a
`split_lines` via `flat_map`+mutable-ref drops the trailing partial line (no
terminal-value hook) and breaks retry/cleanup; via `scan` it emits the whole
accumulator each step and recovers the leftover only by accident
(`a_current_shape.ml`). A 5-parameter Channel expresses the same transducer
cleanly with leftover carry and a typed `done` value. The executable fixture
names and observed output are recorded in
`docs/research/evidence/stream-core-reopen/verdict.md`.

## Decision

Add a **public typed-transducer surface** (a Channel-style type) **alongside**
the existing `Stream.t` and `Sink.t`. Do not replace them.

The new type carries, at most:

```ocaml
type ('out_elem, 'out_done, 'in_elem, 'in_done, 'err) channel
```

with the ZChannel-shape primitives:

- write / emit output elements;
- succeed with a typed terminal (`'out_done`) value;
- fail with a typed `'err`;
- `readWith`: branch on upstream element, upstream terminal, and upstream error.

`Stream.t` is the write-only case (`'in_*` free, `'out_done = unit`); `Sink.t`
is the read-only case (`'out_elem` absent, `'out_done` = the sink result); a
**Transducer** is the read+write case. This is the decomposition Effect-TS/ZIO
use, sized to Eta's single-error-row, env-absorbed type system.

Concrete shapes (names and exact primitive set) are a follow-up design step.
The required behavior, proven by evidence:

- streaming, chunk-by-chunk, bounded memory;
- leftover held in-channel, not in external mutable state;
- a typed terminal value emitted on clean upstream EOF;
- distinct upstream-EOF vs upstream-error handling;
- typed-error-row preservation through `run` (negative-tested);
- resource cleanup via the existing `Effect.scoped` mechanism (V-S4).

## Alternatives considered

- **Keep Channel internal forever (status quo).** Rejected: the trigger has
  fired; transducers exist in-repo and were built outside the package.
- **Replace `Stream` with a unified Channel core.** Not required by the
  evidence and a larger change. Keep `Stream` for the common case; add Channel
  for the transducer case. Unification is deferred.
- **Public Pull/Cursor instead of Channel.** Rejected for transducers:
  `c_pull_core.ml` shows a pull-based transducer re-implements Channel's
  read/emit/done by hand (carry + pending buffer + upstream terminal + poll
  loop) and collapses terminal-leftover vs terminal-error into one slot. Pull
  is the right *source* abstraction (ADR 0001's `from_effect_reader`), not the
  transducer core.
- **Add only more Stream primitives (split_lines, decode).** Rejected: each
  such primitive is a transducer and would re-derive the read/emit/done/terminal
  protocol ad hoc. A typed surface subsumes them.

## Consequences

Positive:

- `split_lines`, `decode`, gzip, SSE framing, and similar transducers can live
  *inside* `eta_stream` instead of in `lib/http/body` or per-application code.
- A typed terminal value closes the leftover-loss gap that the current shape
  has structurally.
- Stream and Sink are unchanged for existing users; the new surface is additive.

Negative:

- One more public type and a small primitive set to maintain and test.
- `.mli` verbosity is higher for the Channel type than for `Stream.t`
  (mitigated by a 2-parameter type alias for the non-transducer case).
- Naming: `Eta.Channel` already exists as a bounded send/receive backpressure
  primitive (`lib/eta/channel.ml`). The streaming type needs a distinct name
  (for example `Stream.Channel`, or `Transducer`).

## Rollout / migration

Research verdict only in this pass. A follow-up objective should:

1. Decide the public name and whether Stream/Sink are derived from or sit
   beside the Channel type.
2. Add a focused `.mli` and tests for the new surface (positive transducers +
   negative error-row + terminal-value + scoped-resource-cleanup cases).
3. Port `lib/http/body/{stream,transducer}.ml` and the eta-ai SSE parser onto
   the new surface, deleting the hand-rolled `Body.Stream` where it duplicates
   the new primitives.
4. Re-run the Nix gates:
   `nix develop -c dune build @install`,
   `nix develop -c dune runtest --force`,
   `nix develop -c eta-oxcaml-test-shipped`.

## References

- `docs/research/evidence/stream-core-reopen/README.md`
- `docs/research/evidence/stream-core-reopen/verdict.md`
- `docs/research/evidence/stream-core-reopen/candidates.md`
- `lib/http/body/stream.mli`, `lib/http/body/transducer.{ml,mli}`
- `lib/stream/docs/adrs/0001-effect-reader-stream.md`
- `docs/research/journal.md`, pre-rename stream design section (V-S1..V-S10)
