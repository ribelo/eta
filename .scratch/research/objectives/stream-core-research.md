# Objective: Reopen eta_stream Core Shape Research

Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-stream-core-research`
Branch: `research/eta-stream-core-research`

## Goal

Reopen the old stream design decision and decide, with executable evidence,
whether Eta's current `eta_stream` architecture is still the best design, or
whether it should move closer to ZIO / Effect with a public Channel/Pull-style
abstraction.

This is research first. Do not implement a production redesign until the
evidence and verdict justify it.

## Why

The existing rationale in `docs/research/journal.md` under
`effet-stream design - Stream / Sink / Channel (4h research)` chose:

- public `Stream.t` as the core;
- public `Sink.t` as a fold/effectful-fold record;
- internal-only `Channel`;
- pull at the public boundary;
- chunked pulls;
- Eio push/queues only inside concurrent operators.

That decision relied partly on the claim that a public Channel would import too
many type parameters into OCaml APIs. This is not currently convincing enough:
ZIO exposes `ZChannel` in Scala with a rich type shape, and Scala is not
obviously cheaper than OCaml for that style. Treat the old "seven TypeScript
parameters are too expensive" rationale as an unproven hypothesis, not a
settled fact.

Unjustified drift from ZIO / Effect behavior is a bug. Justified drift is fine,
but the justification must be evidence, not taste.

## Research To Reopen

Read and explicitly supersede or reaffirm:

- `docs/research/journal.md`, section `effet-stream design - Stream / Sink / Channel`
  around V-S1..V-S10.
- `docs/research/evidence/stream_research/README.md`
- `docs/research/evidence/stream_research/BACKLOG.md`
- current `lib/stream/eta_stream.mli`
- current `lib/stream/eta_stream.ml`
- `lib/stream/README.md`
- `docs/zio-boundaries.md`
- `.reference/effect-smol/packages/effect/src/Stream.ts`
- `.reference/effect-smol/packages/effect/src/Channel.ts`
- `.reference/effect-smol/packages/effect/src/Sink.ts`
- `.reference/zio/streams/shared/src/main/scala/zio/stream/ZStream.scala`
- `.reference/zio/streams/shared/src/main/scala/zio/stream/ZChannel.scala`
- `.reference/zio/streams/shared/src/main/scala/zio/stream/ZSink.scala`

If any reference path differs, find the real file with `rg --files`.

## Required Method

Use the evidence-based-coding workflow. Keep the hypothesis space alive until
fixtures close it. Do not reject a candidate because it is harder to prove,
unfamiliar, more ZIO-like, or broader than the current design.

Create a bounded lab under local scratch:

```text
.scratch/evidence/stream-core-reopen/
```

Keep only durable markdown conclusions under
`docs/research/evidence/stream-core-reopen/`. At minimum include:

- `README.md` describing the question and proof obligations.
- `candidates.md` with a hypothesis ledger.
- runnable OCaml fixtures/probes for serious candidates in `.scratch`.
- negative fixtures for claimed invariants in `.scratch`.
- `verdict.md` with numbered decisions that supersede or reaffirm V-S1..V-S10.

## Candidate Space

Evaluate at least these candidates fairly:

A. Current Eta shape: public `Stream`, public fold-shaped `Sink`, internal
   Channel, pull boundary, internal queues only for concurrency.

B. Public Channel / ZChannel-like core: a first-class public abstraction capable
   of bidirectional transduction, typed upstream/downstream errors, terminal
   values, and stream/sink derivation.

C. Public Pull/Cursor core: expose a smaller pull abstraction rather than full
   Channel, with explicit close/finalization semantics.

D. Eio-backed pipeline core: public API remains small, but the runtime model is
   push/queue/fiber based more broadly than today.

You may add candidates, but do not drop B without evidence.

## Proof Obligations

Answer these with code, not prose:

1. Can each serious candidate express normal Eta stream user stories with clear
   call sites: map/filter/take/drop, run fold/count/collect, resource source,
   merge, flat_map_par, schedule/retry, timeout, and file cleanup?

2. Can a public Channel-like API express real transducer use cases that current
   Eta either cannot express or must encode awkwardly: split lines, decode text,
   framed parsing, leftovers, terminal decoder state, separate upstream and
   downstream errors?

3. Which invalid states are rejected mechanically? Include negative fixtures for
   error-row preservation, resource/handle escape, unscoped producer use,
   abandoned finalizers, and any public Channel misuse the candidate claims to
   prevent.

4. Does runtime lifecycle match Eta requirements: early `take`, typed failure,
   defect, interruption, downstream sink failure, and concurrent sibling failure
   all clean up resources and preserve causes?

5. Where Eta differs from ZIO / Effect, is the drift behaviorally justified?
   Compare user-observable behavior, not just names. Record each drift as:
   justified, unjustified bug, or intentionally out of scope.

6. If API/type cost is used as an argument, measure or demonstrate it:
   call-site size, inferred interface readability, error-message quality,
   implementation touched surface, compile/build impact if practical. Do not
   treat proof cost as design cost.

## Output

End with:

- `docs/research/evidence/stream-core-reopen/verdict.md`
- a concise docs candidate, preferably
  `lib/stream/docs/adrs/0003-stream-core-shape.md`, if the verdict is clear
  enough to promote;
- exact commands run and results;
- a clear status for every candidate: accepted, rejected, dominated, deferred,
  or still untested;
- the strongest counterevidence against the selected design;
- what evidence would change the decision.

If the current design wins, the verdict must explain why public Channel/Pull did
not win with stronger evidence than "too many parameters". If public Channel or
Pull wins, provide the smallest migration/implementation objective for a follow-up
agent, but do not silently implement the redesign in the research pass.

Use Nix gates for verification:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
```

For scratch-only evidence, also record the focused `dune build` / `dune exec`
commands that run the lab.
