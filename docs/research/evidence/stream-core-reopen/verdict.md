# Verdict — stream core reopen

This entry supersedes or reaffirms `journal.md` `V-S1..V-S10` using executable
evidence in `.scratch/evidence/stream-core-reopen/`.

Research only. No production redesign is implemented in this pass. If a
non-current candidate wins a slice, the smallest follow-up objective is at the
end.

## TL;DR (revised after the one-vs-two-core challenge)

- **One core, not two.** ZIO and Effect each have exactly ONE streaming model:
  a Channel core, with `Stream` and `Sink` as thin derived views, and HTTP
  bodies are `Stream`. There is no precedent for two implementations.
- **The "add Channel alongside Stream" verdict below (V-X1) is wrong** — it is
  unjustified drift from both references and would perpetuate the exact
  fragmentation Eta already suffers (`eta_stream` vs
  `lib/http/body/Stream.ml`). See **V-X6** for the correction.
- **The right design is Channel-as-core, Stream/Sink derived** — the original
  candidate S-A that V-S1 rejected on the (now-falsified) "seven parameters"
  grounds. `Stream.t` becomes a thin view over `Channel`, `Sink.t` the
  read-only view, and HTTP `Body` becomes a `Stream` — eliminating the second
  implementation rather than adding one.
- The current `eta_stream` is Stream-as-core (an operator GADT), so this is a
  genuine redesign; there is no internal Channel to "just expose" (V-S1 picked
  S-B over S-A).
- V-S1 and V-S6 are **superseded**; the "seven parameters" objection is
  **falsified** (5 params in Eta-shaped OCaml, call sites infer).
- Research only; no redesign is implemented here.

---

## Original TL;DR (kept for the audit trail; superseded where marked)

## TL;DR

- **V-S1 is superseded.** A public Channel does **not** cost "seven parameters"
  in OCaml. It costs **5**, and call sites infer with **zero** annotations.
- **V-S6 is superseded.** The "revisit when we need a transducer" trigger has
  **fired in production** (`lib/http/body/Stream.ml` + `transducer.ml`), and a
  Channel expresses the transducer cleanly while the current shape provably
  cannot.
- **The decision is not "replace Stream with Channel".** It is: **add a public
  typed-transducer surface (a Channel) alongside the existing Stream**, because
  the two are complementary. Keep A's small surface for the common case; add
  B's typed terminal value + bidirectional transduction for the cases A
  structurally cannot express.
- C (Pull) is **dominated**: it is the current pull boundary + ADR-0001's
  finalizer, and for transducers it re-invents Channel's input side by hand.
- D (Eio pipeline) is **unchanged**: push/queue/fiber stays the internal
  implementation of concurrency (V-S2 reaffirmed).

## Decision diary

### V-X1 — Reopen V-S1/V-S6: expose a public typed-transducer surface
Status: **ACCEPT**
Decision: Eta should add a public Channel-style type with a typed terminal
(`done`) value and bidirectional transduction, alongside (not replacing) the
current `Stream.t`. The current shape cannot express transducers; the need is
real and already realised in production outside the package.
Evidence:
- `a_current_shape.ml`: the current operator surface cannot express a streaming
  `split_lines`. `flat_map`+mutable-ref **drops** the trailing partial line
  (no terminal-value hook) and breaks retry/cleanup; `scan` emits the whole
  accumulator each step and only recovers the leftover by accident in a fold.
- `b_channel_transducer.ml`: a 5-parameter Channel expresses the same
  `split_lines` with leftover carry, emits complete lines as they arrive, and
  returns the trailing `"cd"` as a typed `done` value. Runs end-to-end.
- `lib/http/body/Stream.ml` + `transducer.ml`: the HTTP response body is a
  separate hand-rolled pull type (`of_reader ~release`, `Chunk|Last|End`) with
  a stateful gzip transducer (leftover `Gz.Inf.src_rem`, terminal decoder
  state, release finalizer). It does not use `eta_stream`.
Counterevidence considered: maybe transducers are rare enough that A + a few
primitives suffice. Rebutted: gzip decode/encode and SSE/line-splitting already
exist in the codebase; ADR-0001 already proposes re-adding a pull source with a
finalizer because the current shape lacks it.
Remaining uncertainty: whether the public type should be one unified Channel
(Stream+Sink+Transducer all derived) or a Channel/Transducer kept beside a
separate Stream. This is a follow-up design decision; it does not block V-X1.
Confidence: **High.** The "cannot express" result for A is structural, not a
matter of taste.
Would change if: a concrete current-shape encoding of `split_lines` were shown
that preserves the terminal value, owns leftover in-stream, and is
retry/interruption-safe — with code, not prose.

### V-X2 — The "seven parameters" objection is not supported
Status: **ACCEPT** (supersedes the V-S1 rationale)
Decision: Drop the claim that a public Channel is too expensive because of its
parameter count. In Eta-shaped OCaml the count is **5, not 7**.
Evidence:
- Effect-TS/Scala carry `OutElem, OutErr, OutDone, InElem, InErr, InDone, Env`.
- Eta has a single typed-error row → `OutErr` and `InErr` collapse to one
  `'err`. Env is absorbed into the embedded `('a,'err) Effect.t`, as the real
  `eta_stream` already does. → `('out_elem,'out_done,'in_elem,'in_done,'err)`.
- `d_type_burden.ml`, measurement 1: a realistic `source |> map |> map`
  pipeline compiles with **zero** type annotations. The parameters never
  surface at call sites.
- `d_type_burden.ml`, measurement 2: the `.mli` verbosity cost is real but
  confined to the library; a type alias
  `type ('a,'err) stream = ('a,unit,_,unit,'err) channel` recovers the
  2-parameter surface for the non-transducer case.
- `neg_error_row.ml`: error-row preservation and message quality
  ("These two variant types have no intersection") match the current shape.
Counterevidence considered: Scala/TypeScript lean on variance + defaults to
absorb unused params; OCaml has neither. Rebutted: OCaml's polymorphic-variant
rows unify structurally, `_` wildcards absorb unused params in signatures, and
inference means call sites never write them. The variance gap is real for the
*type system* but not for *user-written code*.
Confidence: **High.** Measured, not asserted.
Would change if: realistic transducer call sites were shown to require
unwieldy annotations that inference cannot resolve.

### V-X3 — Candidate A (current shape) stays for the common case
Status: **ACCEPT** (reaffirms the non-transducer parts of V-S1, V-S3, V-S5)
Decision: Keep the current public `Stream.t` (chunked pull, single `'err` row)
and fold `Sink.t` for the common map/filter/take/run/fold/merge/flat_map_par
story. They are the right, smallest surface for that story and inference is
trivial.
Evidence: the current `lib/stream/eta_stream.mli` surface; `a_current_shape.ml`
shows map/scan/flat_map/fold all infer cleanly.
Confidence: **High.**

### V-X4 — Candidate C (Pull/Cursor) is dominated for transducers
Status: **REJECT** (as a transducer core)
Decision: Do not make a standalone Pull/Cursor the transducer core. It is the
right *source* abstraction (it is what A's pull boundary + ADR-0001's finalizer
already are), but for transducers it re-implements Channel's input side by hand
and loses the `in_done`/`in_err` separation.
Evidence: `c_pull_core.ml` works (emits `a`,`b`, terminal `"cd"`) but carries
hand-rolled `carry` + `pending` buffer + `upstream_terminal` + `pending_error`
+ a poll loop, and cannot hold a terminal leftover AND a terminal error in one
result slot. B gives both natively as `in_done` / `in_err`.
Confidence: **High.**
Note: the ADR-0001 `from_effect_reader` / `unfold_resource` source is still
valuable and orthogonal — it is the *source* half, not the transducer core.

### V-X5 — Candidate D (Eio pipeline) unchanged
Status: **OUT OF SCOPE** for this question
Decision: Push/queue/fiber stays the internal implementation of concurrency
(`merge`, `flat_map_par`). V-S2's finding still holds: making every operator a
live queue allocates fibers/buffers for purely sequential pipelines.
Confidence: **High** (unchanged from V-S2).

### V-X6 — One core, not two: Channel-as-core, Stream/Sink derived
Status: **ACCEPT** (supersedes the "alongside" framing in V-X1)
Decision: Do NOT add a Channel alongside the existing Stream. Make Channel the
single core, with `Stream.t` and `Sink.t` as thin derived views over it, exactly
as ZIO and Effect do. The HTTP `Body` then becomes a `Stream`, eliminating the
separate `lib/http/body/Stream.ml`.
Evidence (the factual answer to "do ZIO/Effect use one core for HTTP, or two?"):
- Effect-TS `Stream<A,E,R>` literally holds a Channel:
  `readonly channel: Channel.Channel<NonEmptyReadonlyArray<A>, E, void,
  unknown, unknown, unknown, R>`. ONE model; Stream is the input-fixed view.
- ZIO `final class ZStream[-R,+E,+A] private (val channel: ZChannel[R, Any,
  Any, Any, E, Chunk[A], Any])`. ONE model; Stream wraps one ZChannel.
- ZIO `final class ZSink[-R,+E,-In,+L,+Z] private (val channel: ZChannel[...])`.
  Sink is the read-only view over the SAME core.
- ZIO Stream operators are thin Channel compositions: e.g. `collectZIO` is
  `new ZStream(self.channel >>> loop(...))`; `loop` is a `readWithCause`.
  There is exactly ONE implementation in ZIO and ONE in Effect.
- zio-http uses ZStream for bodies: `Body.asStream: ZStream[Any, Throwable,
  Byte]`, `Body.fromStreamChunked(stream: ZStream[...])`. There is NO separate
  body-stream type. The HTTP body IS the unified Stream.
Why the V-X1 "alongside" framing was wrong:
- It proposed two public types with separate implementations — exactly the
  fragmentation Eta already suffers (`eta_stream` Stream-GADT vs HTTP
  `Body.Stream`). Adding a Channel beside Stream would not unify them; it would
  add a third thing.
- The project rule says unjustified drift from ZIO/Effect is a bug. Both
  references have ONE core. Two is the drift.
- The current `eta_stream` is Stream-as-core (an operator GADT; see
  `lib/stream/eta_stream.ml` lines 19-40). There is no internal Channel to
  expose — V-S1 explicitly chose S-B (Stream-core) over S-A (Channel-core).
  So the one-core model is a genuine redesign: redefine Stream/Sink as views
  over a Channel core, then HTTP reuses Stream.
What stays from V-X1..V-X5:
- The transducer gap is real (V-X1 evidence stands): a Channel is required to
  express split_lines/gzip/SSE with a typed terminal value.
- The "seven parameters" objection is still falsified (V-X2): 5 params, infers.
- C (Pull) is still dominated as a transducer core; but it is the right
  *internal execution strategy* for a Channel (pull at the boundary), so the
  Channel's runner can be pull-driven without a separate public Pull type.
- D (Eio pipeline) still owns concurrency internals.
The 5 params do NOT drag behind Stream (module + functor correction):
- The "drag" only happens with a *transparent type alias* (`type t = channel`),
  which is definitionally equal to the 5-param type and expands everywhere.
- With a *sealed/abstract module* (`module Stream : sig type ('a,'err) t end =
  struct type ('a,'err) t = <channel> end`), `Stream.t` is abstract with exactly
  2 params in the public signature; the 5-param channel is the implementation,
  never the surface. A `private` abbreviation gives the zero-allocation middle
  ground. A functor factors the one core into the Stream/Sink views.
- Proven by `e_one_core_views.ml`: a SEALED `STREAM_PUBLIC` whose `t` is abstract
  2-param, backed by a 5-param channel, with a `to_channel`/`of_channel` bridge
  the only place the channel surfaces. Compiles and runs with 2-param inference.
  (The compile error while writing it reinforced the point: claiming the input
  side polymorphic when it is fixed was rejected — abstraction controls exactly
  what escapes.)
- Therefore the public Stream `.mli` is identical to today (`('a,'err) t`, `map`,
  `run_fold`); the 5 params live only in the `Channel` module `.mli` + `.ml`.
  This *strengthens* the one-core model: ZIO/Effect-faithful AND a clean surface.
Counterevidence / honest cost:
- Channel-as-core means the existing Stream-GADT operators are reimplemented as
  Channel-primitive compositions (`self.channel >>> ...`). This is more
  indirect than the current GADT and is real implementation work. Under the
  research rule (churn/difficulty out of scope) this does not decide against it;
  it is a follow-up cost.
Confidence: **High** on the direction (one core, sealed derived views, no
param drag); **Medium** on the exact OCaml type-expression of the "derived
view" (abstract type vs `private` abbreviation vs functor) — a follow-up design
sub-decision.
Would change if: an OCaml-specific reason were found that makes a single
Channel core materially worse than ZIO/Effect's. Not found yet; the param-drag
concern, the obvious candidate, is disproven by `e_one_core_views.ml`.

### V-X7 — The Stream↔Channel bridge: abstract vs `private`
Status: **ACCEPT** (abstract); `private` is **REJECTED** as the default, kept
as a possible internal optimization.
Decision: expose `Stream.t` (and `Sink.t`) as **sealed abstract** types over
the channel core, reached by named `to_channel`/`of_channel`. Do not use a
`private` type abbreviation for the public Stream surface.
Evidence (realistic `Stream → split_lines → Stream` round trip, both variants,
over one channel core — `f_bridge_round_trip.ml` + `bridge_lib.ml`):
- Both bridges carry the IDENTICAL round trip: input `"a\nb" "\nc" "d"` →
  lines `[a; b]` plus the trailing partial `"cd"` (as a typed terminal value,
  then as a final emitted line). Typed terminal value is real and reachable:
  `Channel.run_fold` returns `(lines, leftover)`.
- The transducer is a FIRST-CLASS channel value (via a `Compose`/pipe
  constructor), so the round-trip result is a lazily-composable stream, not an
  eager run. This is the realistic case the user asked for.
- Encapsulation, proven by compile-time negatives:
  - `neg_abstract_coerce`: abstract `Stream.t` is a fresh nominal type;
    `(s :> channel)` is REJECTED outside — only the named bridge reaches it.
  - `neg_private_construct`: `private` does NOT allow constructing a `Stream.t`
    from a `Channel.t` outside — the backward bridge still needs `of_channel`.
  - `neg_private_match`: a `private` *abbreviation* does NOT allow
    pattern-matching the underlying channel — so it does not leak the
    representation via matching (only `private` *data types* would).
  - inline in `f_bridge_round_trip.ml`: `private` DOES allow `(s :> channel)`
    forward from outside (the one thing abstract forbids).
Why abstract wins:
- `private`'s only advantage is the forward `(:>)` coercion; but the backward
  direction (`of_channel`) is REQUIRED in both. So a round trip under `private`
  is `(s :> channel) ... |> of_channel` — half coercion, half named function —
  LESS uniform than abstract's `to_channel ... |> of_channel`.
- The `(:>)` coercion forces the caller to spell the target channel type;
  named `to_channel` infers it. So `private` is also less ergonomic at the call
  site, not more.
- Abstract fully hides the representation; `private` advertises it (even if
  matching is blocked, the `.mli` says `= private Channel.t`). For a core whose
  channel is an implementation detail, abstract is the stronger boundary.
- Both are ZERO allocation: `to_channel`/`of_channel` and `(:>)` are all
  identity; the abstract `t` is transparently `channel` inside the module. So
  allocation does not decide between them.
Where `private` could still earn a place: as an INTERNAL representation choice
inside the library (so library modules reach the channel without identity
function indirection), never as the public `Stream` surface. That is a
follow-up micro-decision, not a public-API question.
Counterevidence: none found that `private` improves the public round trip.
Confidence: **High.**
Would change if: `private` were shown to remove a real allocation the abstract
identity bridge pays (not the case here) or to materially clean up call sites
(it does the opposite).

## Per-verdict mapping to the original V-S1..V-S10

| Original | Disposition | Reason |
| --- | --- | --- |
| V-S1 (Stream-as-core, Channel internal) | **Superseded** by V-X1/V-X2 | "Seven params" falsified (5, infers); Channel needed for transducers |
| V-S2 (pull at boundary, push internal) | **Reaffirmed** | Pull boundary correct; push stays internal (V-X5) |
| V-S3 (chunked pulls) | **Reaffirmed** | Unchanged; orthogonal to the transducer question |
| V-S4 (reuse Effect.scoped for resources) | **Reaffirmed** | Unchanged; Channel sources/transducers also close via scope |
| V-S5 (fold Sink) | **Reaffirmed for sinks** | A Sink is a read-only Channel; fold sinks stay |
| V-S6 (Channel internal; revisit on transducers) | **Superseded** by V-X1 | Trigger fired (HTTP gzip/SSE); Channel expresses it, A cannot |
| V-S7 (primitive vs combinator split) | **Reaffirmed** | Unchanged; a Channel adds primitives for read/emit/done |
| V-S8 (Eio interop; byte source) | **Reaffirmed, extended** | `from_file` stays; a Channel lets `split_lines`/decode live in-stream instead of in `lib/http/body` |
| V-S9 (tracer: per-chunk spans) | **Reaffirmed** | Unchanged |
| V-S10 (stub mli) | **Superseded** by follow-up mli | A new ADR + mli for the public Channel/transducer surface |

## Strongest counterevidence / risk

- The Channel's `.mli` is more verbose (5 params repeated) than the current
  `Stream.t` (2 params). Mitigated by a type alias for the non-transducer case,
  and the cost is confined to the library's own interface, not user call sites.
- One could still argue transducers are rare. Rebutted by gzip + SSE + line
  splitting already existing in-repo, two of them outside `eta_stream`.
- A unified-Channel core (Stream and Sink *derived* from Channel) is more
  elegant but a bigger change than the evidence strictly requires. The minimal
  proven slice is "add a transducer-capable type beside Stream", which V-X1
  settles; whether to go further is a separate, deferred design decision.

## What would change the decision

- A concrete, in-stream `split_lines` (or gzip/SSE) under the *current* shape
  that preserves the terminal value, owns leftover, and is retry/interruption
  safe — shown as code, not prose. (We tried; it drops the terminal value.)
- Evidence that realistic transducer call sites require unwieldy annotations.
- Evidence that the HTTP body path can be moved onto `eta_stream` *without* a
  typed-transducer surface (i.e. A can host it after all).

## Deferred

- Whether the public type is one unified Channel (Stream+Sink derived) or a
  Channel/Transducer beside a separate Stream — a follow-up design decision.
- Whether to port `lib/http/body/{stream,transducer}.ml` onto the new surface
  — implementation work, not part of this research pass.
- A full Channel `readWithCause` / leftovers-as-values API — only the typed
  terminal + bidirectional core is proven necessary here.

## Commands run (reproducible)

```sh
# switch: 5.2.0+ox (also builds on 5.4.1; lab needs only Dune)
dune build --root .scratch \
  evidence/stream-core-reopen/a_current_shape.exe \
  evidence/stream-core-reopen/b_channel_transducer.exe \
  evidence/stream-core-reopen/c_pull_core.exe \
  evidence/stream-core-reopen/d_type_burden.exe
dune exec --root .scratch ./evidence/stream-core-reopen/a_current_shape.exe
dune exec --root .scratch ./evidence/stream-core-reopen/b_channel_transducer.exe
dune exec --root .scratch ./evidence/stream-core-reopen/c_pull_core.exe
dune exec --root .scratch ./evidence/stream-core-reopen/d_type_burden.exe
# negative (add stanza to dune, then):
dune build --root .scratch evidence/stream-core-reopen/neg_error_row.exe
# -> "These two variant types have no intersection"
```

### Observed output

```
# a_current_shape (candidate A — current shape)
attempt1 (flat_map+ref) lines: [a; b]
  -> the trailing partial line is DROPPED (no terminal value)
attempt2 (scan) emits whole accumulator each step:
  step lines=[a] carry="b"
  step lines=[b; a] carry="c"
  step lines=[b; a] carry="cd"

# b_channel_transducer (candidate B — public Channel)
split_lines emitted: a | b
split_lines terminal leftover: cd

# c_pull_core (candidate C — public Pull)
pull split_lines emitted: a | b
pull split_lines terminal leftover: cd

# d_type_burden
measurement: call-site pipeline compiled with ZERO annotations.
measurement: channel .mli writes 5 params; an alias recovers 2.
measurement: error quality matches the current eta_stream shape.
```

## Shipped code ↔ journal agreement

This pass ships **research only**: the lab under
`.scratch/evidence/stream-core-reopen/` and the proposed ADR at
`lib/stream/docs/adrs/0003-stream-core-shape.md`. No `lib/stream/` production
code is changed. The journal verdict (V-X1..V-X5) and the lab agree: candidate
A stays for the common case; a public typed-transducer surface (Channel) should
be added; the "seven parameters" objection is dropped.

## Nix gate verification (baseline, no production code changed)

All three gates pass (this pass added only the ADR markdown and the scratch
lab, so these confirm a clean baseline):

```sh
nix develop -c dune build @install          # exit 0
nix develop -c dune runtest --force         # Test Successful (exit 0)
nix develop -c eta-oxcaml-test-shipped      # Test Successful (exit 0)
```

The focused lab commands (above) also build and run on both the `5.2.0+ox`
switch and the ambient `5.4.1` switch.
