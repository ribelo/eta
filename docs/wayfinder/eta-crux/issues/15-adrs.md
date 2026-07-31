# ADRs for the four settled architecture decisions

Type: task
Status: open
Blocked by: 04

## Question

Write four ADRs under `docs/adrs/`, numbered from 0003, recording decisions already made.
Each rejects a named alternative from a reference implementation, which is exactly the
rationale a requirement note is forbidden to carry — and the reason these decisions were hard
to recall from the notes alone a month later.

1. **Command is a bare force-total Eta effect, not a wrapper.** The type is
   `('action, nothing) Eta.Effect.t`. Rejects Foldkit's `{ name; args; effect }`, which
   exists only because Effect-TS effects are anonymous closures it must name to trace and to
   assert on structurally; Eta effects already carry `Effect.named` and `Effect.annotate`,
   both surfacing in traces and defect diagnostics. Accepted cost: no
   assert-the-command-value testing, so tests assert the typed result action plus ordered
   pending-command handles.
2. **Lean `eta_signal` plus a sibling `eta_signal_map`.** Incremental's core has no `assoc`;
   keyed collections live in the separate `Incr_map` package over `Map.symmetric_diff`, and
   `Bonsai.assoc` builds on that. Rejects putting `assoc` in the engine core, and rejects
   hand-rolling keyed diffing over `bind`. Hard to reverse because it is a package boundary.
3. **Functored engine, threaded app-facing graph.** `eta_signal` stays generative like
   Incremental's `Make ()`, giving disjoint node types per application; eta_crux mints one
   instance internally and threads a graph value like Bonsai's `cont`. Rejects exposing the
   functor to application code, which dynamic structure forbids anyway, since a functor
   cannot be applied at runtime inside a scope. Trade-off: generativity buys compile-time
   cross-graph isolation, the threaded value buys composability.
4. **Shell interaction is symmetric messaging.** Rejects Crux's `Operation`, `Request`,
   `RequestHandle` and `Core::resolve`, which exist because Crux's core is a serialized Wasm
   sandbox that loses its continuation across the boundary.

Blocked by ticket 04, which may narrow the fourth claim from "no request mechanism" to "no
serialized request machinery". The first three could be drafted earlier if that becomes
useful.

Ground every claim in the local reference checkouts rather than memory, and cite the file and
symbol each claim rests on.
