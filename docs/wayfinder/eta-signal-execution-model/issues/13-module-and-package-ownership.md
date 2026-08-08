# Module and package ownership

Type: grilling
Status: resolved
Blocked by: 09, 12, 17

## Question

Which modules own the selected kernel, effect seam, structural machinery,
Signal Map integration, and any new Eta runtime primitive?

Give each module one named invariant and one small interface. Keep optional
dependencies out of the root Eta package.

Use the promoted production implementation as the subject.
Move code directly when the ownership decision is complete.

## Answer

Three ownership modules live in one wrapped private library
(`lib/signal/kernel`, dune library `eta_signal_kernel`, package `eta_signal`,
no `public_name`, never installed). The old `eta_signal_engine` library is
deleted. The public shell `lib/signal/eta_signal.ml` is unchanged and still
includes `Eta_signal_kernel.Graph`.

**Q1 (the subject).** The ownership unit is the kernel below the public
shell: three modules with one named invariant each.

- `Propagation` (`lib/signal/kernel/propagation.ml`, formerly
  `selected_core`). Invariant: generation-safe topological freshness with
  rollback. It owns node storage, scopes, slots, admission, the recompute
  queue, freshness detection, keyed reconciliation, and value rollback.
- `Post_commit` (`lib/signal/kernel/post_commit.ml`, formerly
  `selected_edges`). Invariant: opaque post-commit settlement. It owns
  observer claims, acknowledgements, timer generations, cleanup, and stream
  acknowledgements, settled only inside its driver. The vestigial
  `Selected_edges.Make (Edge_execution)` functor is deleted; the module is a
  plain structure.
- `Graph` (`lib/signal/kernel/graph.ml`, the former `Make_impl` functor,
  renamed `Graph.Make`). Invariant: owner-domain phase authority. It owns the
  single phase machine (`Idle | Planning | Delivering`), every effect and
  daemon re-entry fence, and the assembly of the public interface.

The DAG is a sandwich: `Propagation` and `Post_commit` are independent leaves
(neither imports the other or Eta); `Graph` composes both and is the only
module that references `Eta.Effect`.

**Q2 (the map boundary).** `eta_signal_map` consumes only the public
`Package_graph` protocol. The internal `Eta_signal_map_api.Make` functor and
its `Keyed.Testing` token seam are deleted, and the map api library no longer
depends on `eta_signal_kernel` at all. The existing
`keyed_testing_negative` fixture pins the public absence of
`Eta_signal_map.Make ... Keyed.Testing`.

**Q3 (naming).** `Propagation`, `Post_commit`, `Graph`. The names state
responsibilities, not implementation history.

**Q4 (library granularity).** One wrapped library, matching the reference
shape (`incremental/src` is one flat library of 42 modules). Direction is
enforced by OCaml acyclicity plus explicit `propagation.mli` /
`post_commit.mli` boundaries. `private_modules` is deliberately not used: it
would hide `Propagation` from the repo-private typed probe, and the
uninstalled-library boundary is the real fence for external consumers.

**Q5 (test access).** A typed repo-private probe
(`test/signal_map/probe`, non-installed library
`eta_signal_map_test_support`) replaces the `Obj.t` token seam. It
instantiates `Graph.Make_impl` (the unconstrained internal signature) and the
production map adapter, and exposes typed `family`/`entry` handles. The
interface carries no `Obj.t`; the single representation cast is isolated in
`family/1` and physical identity for existential projections is compared
through `Obj.repr` internally. Three checks that were fake or weak under the
old seam are now real:

- `has_exact_child_edge` counts the actual child-to-owner dependent edge
  (the seam hard-coded `true`).
- `is_settled` inspects committed-input synchronization plus per-child edge
  and scope integrity (the seam compared two input roots; it also passed
  vacuously when an owner was reclaimed - the ported property 35 now
  requires a surviving family to be settled).
- `fail_next_precommit` injects one shot at the real pre-commit barrier
  (after candidate planning, before the detach/invalidate/attach sweep) via
  a new `Propagation.precommit` hook. The old pre-planning `preflight` hook
  is deleted with the seam. One diagnostics expectation moves from 2 to 3
  registered provisional scopes because the barrier defect now fires after
  planning legitimately builds the plan.

All 38 keyed QCheck properties and all 12 diagnostics run against the probe
plus public protocol. `raw_for_testing` stays on `Graph.Make_impl` as the
probe's door; it is not in the `Result` signature and never reaches the
public surface.

Implementation summary:

- One phase machine. `Graph` owns `Idle | Planning | Delivering` with a
  `with_phase` bracket. The overlapping `Propagation.phase`
  (`Idle | Active | Cleanup_pending`), `graph.running`, and the factory
  `delivering` ref are gone. Construction guards read the phase: `Var.value`
  rejects `Planning` only; stabilize rejects `Delivering`.
- Fence fixes (both review-verified holes): `update_effect`'s `E.on_exit`
  finalizer branches now call `ensure_context ()` before mutating graph
  state, and the timer daemon body fences at its top, outside the `try`, so
  violations escape loudly instead of corrupting post-commit state.
- All factory record manipulation (slots, admissions, free lists, queue
  links, scope records, change listeners, generations) moved down into named
  `Propagation` operations. `propagation.mli` and `post_commit.mli` declare
  the boundary; internal pass machinery, queue cursors, timer state, hook
  tables, and growth helpers are hidden.
- One traversal subtlety is preserved exactly: scope validation recurses only
  through scoped nodes (two bind tests pin this).

Deliberate deferrals:

- Representations stay concrete in the `.mli` files. Typed value storage is
  ticket 16's ownership decision; abstracting now would just re-open it
  there.
- `has_pending_bind` still reads a queue mark through the factory's
  `bind_evaluations` table. The bind-evaluation representation belongs to
  tickets 15/16.
- `Make_impl` keeps its historical name for the unconstrained internal
  signature (the constrained public functor is `Graph.Make`). Renaming it is
  ticket 14's spec-consolidation call.

Behavior found and pinned during implementation:

- A defect from `now_ms` during a timer daemon wake kills the daemon, the
  same stabilize's refresh pass admits the catch-up ticks, and the daemon
  never restarts - even after a delivery-bearing stabilize
  (`timer_daemon_wake_defect_keeps_timer_value_and_stops_sleeping` in
  `test/signal/test_eta_signal.ml`). The no-restart half is a latent defect
  candidate; it is pinned, not fixed, and belongs to ticket 14's execution
  specification.

Gates at resolution: `dune runtest --force`, `dune build @install`, both
negative fixture suites, and `eta-oxcaml-test-shipped` all green.
