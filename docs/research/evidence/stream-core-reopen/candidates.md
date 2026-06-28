# Candidate ledger — stream core reopen

| Candidate | Why plausible | Evidence needed to win | Evidence that would falsify | Current evidence | Status |
| --- | --- | --- | --- | --- | --- |
| **A. Current shape** — public `Stream` (2 params) + fold `Sink`, internal Channel, pull boundary | Smallest public surface; matches what shipped; call sites infer trivially. | Express the real transducer use cases (split/decode/frame) without losing the terminal value or leaking state. | Any real transducer that forces external mutable state or drops the terminal value. | `a_current_shape.ml`: split_lines via `flat_map`+mutable ref DROPS the trailing partial line `"cd"`; via `scan` it emits the whole accumulator each step and only recovers the leftover by accident in a fold result. Real transducers were built outside the package (`lib/http/body/`). | **Contradicted** for transducers (P1, P2, P5). Still best surface for the *non-transducer* common case. |
| **B. Public Channel / ZChannel-like** | Effect-TS/ZIO's unified core; can express Stream (write-only), Sink (read-only), and Transducer (read+write) with typed terminal value and distinct upstream/downstream channels. | Express a real streaming transducer with leftover + terminal value, at ≤5 params, with call sites inferring. | Fails to express the transducer, OR forces annotations at every call site, OR breaks error-row preservation. | `b_channel_transducer.ml`: split_lines emits `a`,`b` and returns `"cd"` as a typed `done` value; 5 params (not 7); call sites need ZERO annotations (`d_type_burden.ml`); error row preserved (`neg_error_row.ml`). | **Accepted** for the transducer slice. |
| **C. Public Pull / Cursor** | Smallest streaming abstraction; basically the current eta_stream pull boundary made first-class with a finalizer. Matches `lib/http/body/Stream.of_reader ~release` and ADR-0001's `from_effect_reader`. | Express sources/maps cleanly AND the transducer without re-inventing Channel's read/emit/done. | Transducer under Pull must hand-roll leftover buffer + upstream-pull + terminal, and collapse leftover-vs-error into one slot. | `c_pull_core.ml`: works (emits `a`,`b`, terminal `"cd"`) but re-implements Channel's input side by hand (carry + pending buffer + upstream_terminal + pending_error + poll loop) and cannot carry terminal leftover AND terminal error in one result slot. | **Dominated** by B for the transducer case; viable as the *source* surface (it is what A already is). |
| **D. Eio-backed pipeline** (push/queue/fiber) | Natural for concurrent operators; already used inside `merge`/`flat_map_par`. | Express the transducer and bounded-memory streaming with push semantics. | Push makes early termination a cancellation problem at every stage (V-S2 finding); fibers/queues allocated for purely sequential pipelines. | Not rebuilt here; V-S2's finding still holds. Push is the right *implementation* of concurrency, not the public *transducer* surface. | **Out of scope** for the transducer question; unchanged from V-S2. |

## Parameters: the "seven parameters" claim, closed

Effect-TS / Scala `Channel`/`ZChannel` carry **7** parameters:
`OutElem, OutErr, OutDone, InElem, InErr, InDone, Env`.

In Eta-shaped OCaml (`b_channel_transducer.ml`, `d_type_burden.ml`):

- `OutErr` and `InErr` **collapse to one `'err`**, because Eta streams have a
  single polymorphic-variant typed-error row (the current `Stream.t` already
  proves this — it is `('a, 'err) t`, one row).
- `Env` **disappears**, absorbed into the embedded `('a,'err) Effect.t`,
  exactly as the real `eta_stream` already absorbs env.

Result: **5 parameters**, not 7. And call sites infer with **zero** annotations
(`d_type_burden.ml`, measurement 1). The cost is confined to the library's own
`.mli`, where a type alias (`type ('a,'err) stream = ('a,unit,_,unit,'err) channel`)
recovers the 2-parameter surface for the non-transducer case.

V-S1's "seven parameters are too expensive" is **not supported** by OCaml
inference evidence. It is superseded.

## What each candidate owns

- **A** owns: chunked pull, fold sinks, the common map/filter/take/run story.
- **B** owns (additionally): typed terminal/done values, bidirectional
  transduction, distinct upstream-downstream error/done channels, leftovers.
- **C** owns: a first-class cursor with finalizer (the source half).
- **D** owns: concurrent operator implementation (push/queue/fiber internals).

The evidence says A and B are **complementary**, not alternatives: keep A's
small surface for the common case, add B's typed-transducer surface for the
cases A provably cannot express. C is subsumed (it is A's pull boundary +
ADR-0001's finalizer). D stays internal.
