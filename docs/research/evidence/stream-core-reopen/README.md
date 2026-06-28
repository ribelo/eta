# Stream core shape — reopen

This lab reopens Eta's `eta_stream` core design decision (journal `V-S1..V-S10`)
with executable OCaml evidence. It asks one question:

> Is Eta's current public shape — `Stream.t` (chunked pull, 2 type params) +
> fold `Sink.t` + internal-only Channel — still the right core, or should Eta
> expose a public transducer-capable abstraction (Channel / ZChannel-like, or a
> Pull/Cursor with a typed terminal value)?

The old decision rejected a public Channel partly on the claim that "making
Channel public imports seven parameters into OCaml APIs". The objective treats
that as an unproven hypothesis. This lab tests it.

This is research. No production redesign is implemented here.

## Why reopen now

Two pieces of repo evidence that did not exist (or were not acted on) when
V-S1..V-S10 were written:

1. `lib/http/body/Stream.ml` + `lib/http/body/transducer.ml`. The HTTP
   **response** body path is a *separate*, hand-rolled pull type with
   `of_reader ~release read_fn`, terminal signals `Chunk | Last | End`, and a
   stateful gzip transducer that carries leftover (`Gz.Inf.src_rem`), terminal
   decoder state, and a release finalizer. It does **not** use `eta_stream`.
   This is exactly the V-S6 revisit trigger ("when implementing `decodeText`,
   `splitLines`, or a true transducer API") firing in production, outside the
   stream package.
2. `lib/stream/docs/adrs/0001-effect-reader-stream.md`. The current package
   still lacks an owned effectful pull source with a finalizer
   (`from_effect_reader` / `unfold_resource`). That gap is the source half of
   the same problem the HTTP layer solved by hand.

## Proof obligations

| #  | Proof question | Evidence | Risk | Status |
| -- | -------------- | -------- | ---- | ------ |
| P1 | Can each candidate express a REAL streaming transducer (chunk-by-chunk, leftover, terminal value, distinct upstream-EOF vs upstream-error)? | `b_channel_transducer.ml`, `c_pull_core.ml`, `a_current_shape.ml` | High | Proven (B,C) / Contradicted (A) |
| P2 | Can candidate A express the same transducer, even awkwardly? | `a_current_shape.ml` (attempt1 flat_map+ref, attempt2 scan) | High | Contradicted — terminal value structurally dropped |
| P3 | Does a public Channel really cost "seven parameters" in OCaml? | `d_type_burden.ml` | High | Contradicted — 5 params, call sites infer with zero annotations |
| P4 | Does a Channel preserve the typed-error row through `run`? | `neg_error_row.ml` (compile-time negative) | Medium | Proven |
| P5 | Is the transducer need real, not hypothetical? | `lib/http/body/{stream,transducer}.ml`, ADR 0001 | Medium | Proven (production code) |
| P6 | Runtime lifecycle (early take, typed failure, interruption cleanup)? | Real eta_stream tests in `test/stream` + HTTP body; not re-derived here | Medium | Affirmed via existing real tests |

## How to run

The lab is a self-contained Dune project rooted at `.scratch/` (switch
`5.2.0+ox` or any recent OCaml 5; it only needs Dune, no `eta`/`eio`).

```sh
# build + run all four probes
dune exec --root .scratch ./evidence/stream-core-reopen/a_current_shape.exe
dune exec --root .scratch ./evidence/stream-core-reopen/b_channel_transducer.exe
dune exec --root .scratch ./evidence/stream-core-reopen/c_pull_core.exe
dune exec --root .scratch ./evidence/stream-core-reopen/d_type_burden.exe

# observe the compile-time negative (add the stanza, build, read the error):
# temporarily add an (executable (name neg_error_row) (modules neg_error_row) ...)
# to the dir's dune, then:
dune build --root .scratch evidence/stream-core-reopen/neg_error_row.exe
# expected error: "These two variant types have no intersection"
```

## Files

- `common.ml` — minimal `Effect` model (one typed-error row, like real `eta`).
- `a_current_shape.ml` — candidate A: faithful replica of `eta_stream`'s
  operator surface; shows it cannot express a streaming transducer.
- `b_channel_transducer.ml` — candidate B: public 5-param Channel; split_lines
  with leftover + typed terminal value.
- `c_pull_core.ml` — candidate C: public Pull/Cursor with finalizer; shows
  where Pull is clean (sources/maps) and where it re-invents Channel
  (transducers).
- `d_type_burden.ml` — measures type-parameter burden; call sites infer with
  zero annotations.
- `e_one_core_views.ml` — one core, sealed views: proves the 5 channel params
  do NOT drag behind a sealed/abstract `Stream.t` (the module+functor point).
- `bridge_lib.ml` + `f_bridge_round_trip.ml` — realistic `Stream → split_lines
  → Stream` round trip over one channel core, through BOTH an abstract and a
  `private` Stream view. Compares bridge ergonomics.
- `neg_error_row.ml` — compile-time negative: Channel preserves its error row.
- `neg_abstract_coerce.ml` — abstract `Stream.t` is not a subtype of `channel`
  (`:>` rejected outside).
- `neg_private_construct.ml` — `private` forbids constructing `Stream.t` from
  a `channel` outside.
- `neg_private_match.ml` — `private` abbreviation forbids pattern-matching the
  channel outside (no representation leak).
- `candidates.md` — hypothesis ledger.
- `verdict.md` — numbered decisions superseding/reaffirming V-S1..V-S10
  (V-X1..V-X7).
