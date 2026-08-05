# Eta Signal V1 implementation journal

## 2026-08-04

### Baseline state

The implementation started at commit `6b98144e91e657594e72c6df1da270c62e18dc9d`.
The worktree was clean.
The branch was 115 commits ahead of `origin/master`.

The focused baseline gate passed:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

This gate ran the current Signal and Signal Map suites.
It included 83 core Signal tests, 48 contract tests, and the current model tests.

### Line counts

The production scope contains 21,678 lines in 57 files.
The full scoped OCaml source contains 50,388 lines in 126 files.

Eta Signal and Signal Map contain 15,396 production lines.
Incremental and Incr_map contain 13,534 production lines at the benchmark commits.

See `BASELINE.md` and `baseline/loc/*.tsv` for the method and file manifests.

### Benchmark

The quick smoke test and the full three-run comparison started on logical CPU 2.
The full comparison includes the 100,000-key workloads.

Raw results and the aggregate table will be added after all three runs finish.

### Probe and counter foundation

The first implementation slice added graph-branded private probe operations.
It also added the eight declared planning fault slots.

Each invariant owner now exposes its exact deterministic counter group.
The groups are disabled by default and become active after a probe reset.
This removes benchmark overhead when no economics measurement is active.

The focused counter gate passed:

```sh
nix develop -c dune build @signal-economics
```

The existing cleanup and timer owner tests also passed:

```sh
nix develop -c dune runtest test/signal/cleanup test/signal/timer --force
```

### Acceptance gates

The final result must satisfy all of these gates:

1. The production count is not more than 21,678 lines.
2. The full scoped count is not more than 50,388 lines.
3. Every Eta benchmark workload improves against the saved Eta baseline.
4. Every scalar workload is at most `1.20×` the matching Incremental workload.
5. Every keyed workload is at most `1.20×` the matching Incr_map workload.
6. The deterministic Signal economics gates pass.
7. The required OxCaml and mainline gates pass.

## 2026-08-04 - Baseline benchmark completed

- Ran the supplied full command three times with nine samples per point, pinned to CPU 2.
- The harness was placed inside a clean `git archive` of baseline commit `6b98144e91e657594e72c6df1da270c62e18dc9d`. This makes Dune link the exact repository sources instead of unrelated installed Eta artifacts.
- Raw source-linked runs are `baseline/benchmark/run1.csv`, `run2.csv`, and `run3.csv`.
- `baseline/benchmark/SUMMARY.md` reports the median of the three process-run means and the matching `1.20x` Jane Street ceilings.
- The full harness constructs every candidate before measurement. The current `Eta_signal.Default` candidates therefore share one graph containing the large keyed workloads. This exposes the forbidden graph-wide scans: even scalar updates take seconds in the full run, although an isolated depth-one smoke is about 10.6 microseconds.
- Final acceptance still requires both conditions for every row: improve over this source-linked Eta baseline and remain within the matching Jane Street ceiling. The final benchmark must use the accepted graph factory API; it must not restore a shared default graph to preserve these baseline numbers.

## 2026-08-04 - Slice 2: atomic transaction core

- Replaced monotonic integer transaction IDs with fresh physical identities.
- Replaced per-stage list allocations with a dense transaction cell array and typed staged-cell access. This follows Incremental's dense hot-state layout while preserving Eta rollback.
- Replaced the separate `Idle | Pure | Committed | Delivering` machine and mutable transaction-status fields with one `Idle | Planning | Delivering` phase owner.
- The atomic pass allocates its transaction and workspace before the one phase assignment. `Before_phase_install` therefore leaves exact `Idle` state and queued work.
- Added all eight required planning fault slots, sealed commit plans, total prepared-write interpretation, cleanup resource terminal states, and one-way node/scope lifetimes.
- Deleted `Eta_signal_stabilization`, `Eta_signal_stabilization_pass`, their copied harness paths, and their obsolete unit suites. Moved transaction, cleanup, scope, and node lifetime under the private engine library.
- Added `test/signal/atomic_pass/` with the N1 allocation boundary, all planning fault slots with retry, prepared-write-only commit, cleanup exactly-once transition, and one-way lifetime checks.
- Focused Signal and Signal Map suites pass after the replacement.
- Current production scope is 22,382 physical lines. This is 704 lines above the saved baseline because later engine-owner modules still coexist with the old scan scheduler. Slice 3 must delete those scans and recover the temporary delta; the final gate remains 21,678 lines.

## 2026-08-04 - Slice 3 feasibility plateau

- Replaced the graph-wide keyed pending-plan scan with a direct index.
- Removed eager weak-registry pruning from stabilization.
- The complete Signal and Signal Map suites pass with the indexed scheduler:

```sh
nix develop -c dune build @install
nix develop -c dune runtest test/signal test/signal_map --force
```

- Measured isolated workloads after the scan removal. Each result is the median
  of three samples from the source-linked comparison harness.

| Workload | Jane Street | Eta | Eta / Jane Street | `1.20x` ceiling |
| --- | ---: | ---: | ---: | ---: |
| changed depth 1 | 33.805 ns | 10,626.569 ns | 314.35x | 40.566 ns |
| changed depth 10 | 103.782 ns | 13,680.208 ns | 131.82x | 124.539 ns |
| dynamic switch | 123.336 ns | 20,220.155 ns | 163.95x | 148.003 ns |

- The depth-one Eta workload allocates approximately 8,232 words per
  operation. Incremental allocates approximately zero words.
- The remaining gap is not a graph-size scan. The isolated depth-one result
  stayed near its earlier 9-11 microsecond range after the scan removal.
- The accepted `1.20x` target requires a further 262x reduction for depth one.
  This is a feasibility plateau in the current effectful API and runtime path.

## 2026-08-05 - Slice 3: constructor-slot edges

- Replaced static child-identity deduplication with one topology edge for each
  constructor argument slot.
- Kept the child index for dynamic edges only. Static edges do not use this
  set-like index.
- Updated DOT diagnostics to render parallel argument edges.
- Added a public contract regression for `map2 base base`. The regression
  failed before the implementation change and now verifies two dependency
  edges, two dependent edges, and two rendered DOT edges.
- The complete Signal and Signal Map suites pass:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 3: atomic demand adjustment

- Demand adjustment now records prospective count changes before it publishes
  zero-boundary callbacks.
- A later overflow or underflow restores every earlier count change.
- Added a private invariant-owner regression that forces failure after the root
  count changed. It verifies exact restoration for both overflow and underflow.
- The complete Signal and Signal Map suites pass after the change.

## 2026-08-05 - Slice 3: indexed scheduler removal

- Changed the scheduler queue to an intrusive doubly linked FIFO.
- Necessity loss now removes unclaimed scheduler work through the node's queue
  links. It does not scan the queue.
- Removing scheduler work also releases the matching work-ledger item.
- Added owner-level queue tests and a kernel integration regression. The
  integration test observes a dirty graph, disposes it before stabilization,
  and verifies that the scheduler and work ledger are empty.
- The complete Signal and Signal Map suites pass after the change.

## 2026-08-05 - Slice 3: transactional scheduler attempts

- Stabilization now reads the committed scheduler through an attempt cursor.
  It does not unlink committed entries during planning.
- New planning admissions use a separate attempt-local FIFO.
- Rollback discards local admissions and preserves committed queue links and
  FIFO order.
- Commit clears committed and local scheduler state through the sealed commit
  plan and releases the exact work-ledger count.
- Attempt-local and pending-removal bits are stored on each node. Scheduler
  removal and claim checks do not search an attempt list.
- Added a scheduler-owner regression that claims committed work, admits local
  work, rolls back, and verifies the original committed FIFO and queued bits.
- The complete Signal and Signal Map suites pass after the change.

## 2026-08-05 - Slice 3: guarded O(1) quiescent stabilization

- `stabilize` now checks the work ledger before timer-refresh token creation,
  phase installation, generation advancement, staging, observer collection, or
  `Graph.run_stabilization`.
- The quiescent check records exactly one work-admission check and one
  quiescent return. It does not record an atomic-pass phase entry, commit,
  rollback, or return-to-idle transition.
- The fast path is conservative while timer reconciliation still uses the
  legacy demanded-timer scan: graphs with timer nodes do not take it yet. This
  preserves timer behavior until slice 7 replaces that scan with queued
  timer-reconciliation work.
- The fast path is also phase-guarded. A nested stabilization still reaches the
  atomic pass and receives the typed reentrancy failure.
- Observer candidates and pending deliveries now own `Observer_delivery` work
  items. Registration or signal change admits a candidate item, event
  collection releases it, pending delivery admits another item, and delivery
  acknowledgement, disposal, or invalidation releases it.
- Added a kernel regression proving that a quiescent call keeps the graph
  generation unchanged and advances only the two work counters.
- Updated the two overflow regressions to distinguish the new V1 semantics:
  quiescent stabilization at `max_int` succeeds, while non-quiescent
  stabilization still reports generation or timer-refresh-token overflow.
- The complete Signal and Signal Map suites pass:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 3: explicit dirty-dependency stack

- Replaced the scheduler's direct claim-then-recursive-compute driver with an
  explicit stack of dependency frames.
- Each claimed consumer settles necessary dirty dependencies in edge-slot order
  before evaluation. Shared dependencies evaluate once and later queue claims
  observe the attempt's `Done` state.
- Added generation-branded `Unseen`, `Visiting`, and `Done` scheduler marks.
  A failed attempt cannot leak marks into the retry because the next attempt
  uses a fresh stabilization generation. Reaching a current `Visiting` node
  raises `` `Cycle`` before commit.
- Dirty scheduling, timer-dirty scheduling, and demand-boundary scheduling now
  suppress re-admission while the node is `Visiting` in the current attempt.
- Dependency-edge instrumentation moved from recursive static evaluation to
  stack edge inspection. Claims still count queue claims only; node evaluations
  count nodes the stack submits to the evaluator.
- Added a dirty-diamond regression proving dependency-first order, exact
  claim/edge/evaluation counts, an empty scheduler after commit, and an empty
  work ledger after commit.
- Dynamic bind and keyed prospective-edge closure still use the existing
  evaluator recursion. Closing that frontier is slice 4, not hidden inside this
  scheduler change.
- The complete Signal and Signal Map suites pass:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 3: timer work enters the ledger

- Demanded timer nodes now own one conservative `Timer_reconciliation` work
  item. The item matches the current scan-based reconciler, which schedules
  demanded timer nodes on every non-quiescent stabilization.
- Demand loss releases that item. Timer-demand cleanup pending outside
  stabilization owns one item; claiming it releases it, and failed cleanup
  restores it exactly once.
- Quiescent stabilization no longer checks the timer registry. It trusts the
  work ledger: demanded or cleanup-pending timers enter a stabilization pass,
  while stopped timers with no pending cleanup return in O(1).
- Added a kernel regression proving that a demanded timer causes phase entry,
  prevents a quiescent return, releases its work after observer disposal, and
  then permits an O(1) quiescent call while the timer node remains registered.
- Slice 7 must replace the conservative active-timer item with exact
  desired/actual lifecycle mismatch work and delete the scan-based reconciler.
- The complete Signal and Signal Map suites pass:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 3: cleanup hooks enter the ledger

- Pending observer disposal hooks now own one `Cleanup` work item from the
  moment they are published. Running the hooks releases that item after the
  finalizers, including failure and interruption exits.
- Overwriting pending cleanup hooks is rejected loudly, so cleanup work cannot
  be silently replaced or leaked.
- A kernel regression observes the count inside an `on_finish` hook, proving
  the hook runs while cleanup work is pending and that the ledger returns to
  zero and quiescent O(1) behavior after the hook completes.
- The complete Signal and Signal Map suites pass:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 3: review fixes before commit

- Scheduler rollback now clears `attempt_removed` on every committed FIFO
  entry. A unit regression proves that a node removed during an aborted
  attempt is claimable by the next attempt.
- Keyed topology changes no longer publish during preflight. Keyed removals,
  invalidations, additions, and pending-plan finalization run as a sealed
  commit-plan write that returns its disposal hooks. A fault after prospective
  validation now rolls back pending keyed topology and preserves the committed
  child identity; clearing the fault retries and commits the replacement.
- Observer registration and disposal adjust the observed signal and scope
  owner through one compound demand journal. Overflow restores every touched
  demand count and publishes no demand boundary.
- Edge insertion now validates demand capacity and reserves both adjacency
  vectors before publication. Dynamic-index insertion happens before the
  non-allocating adjacency appends. Static node construction reserves all
  dependency and dependent capacity before attaching constructor edges.
- The full suite rejected lifecycle-only timer quiescence: active timers still
  need the current scan-based on-demand refresh. Slice 3 therefore keeps the
  conservative rule that each demanded timer owns one timer work item, plus
  one pending cleanup item when disposal must force reconciliation. Slice 7
  must replace the scan and then make timer work exact.
- The second high-tier review run completed, but the agent-result channel
  returned an internal decoding error before its final report could be read.
  All findings from the first report are either fixed with regressions or, in
  the timer case, explicitly deferred to slice 7 by full-suite evidence.
- Verified with:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 4: first N2 frontier regression

- Added graph-branded topology probes through the kernel `Extension` seam and
  re-exported them in Signal Map `Testing`. Tests can now inspect signal
  validity, demand, dependent counts, and exact child-to-parent edges without
  DOT text or unsafe object casts. Counter reset now covers topology and demand
  counters as well as the existing keyed counters.
- Closed the first mixed keyed-bind frontier hole: prospective invalidation
  now discards every staged bind whose owner is in the combined bind/keyed
  frontier. Discard rolls back the staged switch, invalidates the provisional
  branch scope, clears the bind and owner staged cells, and moves disposal
  hooks into the cleanup batch before any keyed topology commits.
- Fixed an edge-removal precedence bug exposed by the new topology counters:
  the dynamic-index `match` previously captured the slot reset and removal
  counter update into its fallback arm. Removing an indexed dynamic edge now
  always removes the index entry, resets both edge slots, and records the
  indexed removal.
- Added `test_keyed_removal_discards_nested_bind_switch_to_top_scope`, the
  first exact N2 regression from issue 16. One stabilization switches a nested
  bind toward a top-scope signal and removes its keyed owner. The test proves
  the switched bind is invalid and undemanded, the discarded branch never
  attaches to the top-scope signal, no dynamic edge is inserted, and exactly
  four committed edges are removed.
- Verified with:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 4: discard closes through provisional scopes

- Dynamic discard now runs to a fixed point. A retired staged bind still rolls
  back its provisional branch, but that rollback can invalidate bind or keyed
  owners created inside the branch. The discard loop now rechecks staged bind
  and pending keyed owners after each retirement and clears every operation
  whose owner became invalid before preflight continues.
- Retired keyed plans are discarded through the same path. Their staged owner,
  input, child, and source cells are cleared and provisional scopes are
  invalidated before the surviving keyed set is preflighted.
- Added `test_keyed_removal_clears_nested_bind_pending_state`. The keyed child
  is removed in the same stabilization that stages an outer bind and a second
  bind created inside the outer provisional branch. The regression proves both
  binds are invalid and undemanded, neither staged switch inserts a dynamic
  edge, top-scope dependencies retain no invalid dependents, and the keyed
  pending plan is cleared.
- Verified with:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 4: provisional-branch regression

- Added `test_keyed_removal_invalidates_nested_bind_provisional_scope`. The
  nested bind builds a new map node inside its provisional branch while the
  keyed owner is removed. The regression proves the provisional node is
  invalid and undemanded, its static dependency edge is gone, no dynamic bind
  edge is inserted, and the top-scope dependency has no retained dependents.
- This is the second exact N2 regression from issue 16. The remaining N2 work
  is churn bounding and callback-defect topology preservation.
- Verified with:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 4: callback-defect topology regression

- Exposed per-class work-ledger counts through the graph-branded Signal Map
  testing seam. Private regressions can now prove which work classes remain
  pending without inspecting scheduler or observer internals directly.
- Added `test_keyed_removal_nested_bind_topology_survives_callback_defect`.
  The keyed removal and nested bind switch commit, then observer delivery
  raises a defect. The retired bind remains invalid, the discarded top-scope
  edge is not restored, source/scheduler/cleanup work is drained, and exactly
  one observer-delivery item remains pending. Clearing the defect retries the
  delivery and releases the final work item without reviving retired topology.
- This is the fourth exact N2 regression from issue 16. Only the bounded
  add/remove/switch churn case remains.
- Verified with:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 4: Package endpoint and engine-owned child state

- Added the graph-branded `Signal.Package` endpoint with opaque plans,
  `stable_family`, and `install`. The public input contract is only the pure
  ordered symmetric diff; the public output contract is only empty/set/remove.
- Signal Map `Keyed.mapi` now adapts those pure map operations through
  `Signal.Package` instead of calling the private keyed constructor directly.
- Keyed child state moved into the engine. The family owner now builds its
  child map from the package `compare_key` using a balanced persistent tree;
  collection packages no longer supply child lookup, insertion, removal, or
  traversal handles. This removes the old adapter-owned child-state protocol
  while preserving stable key order and logarithmic child-map operations.
- Keyed raw-input and output records now carry only the operations the engine
  actually uses. The previous adapter-owned diff bundle and full output-map
  operation bundle were deleted.
- The larger factory-shape migration (`Eta_signal_map.Make (Signal.Package)`)
  remains open; the current Signal Map factory still returns the graph module
  for the existing private test seam.
- Verified with:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 4: public Package factory shape

- Public Signal Map construction now has the required shape:
  `Eta_signal_map.Make (Signal.Package)`. The functor no longer takes a
  graph-producing `()` argument and no longer returns or re-exports the graph
  module; its only argument is the graph-branded package endpoint.
- Added public `Eta_signal.Package_graph` as the shared module type. The
  factory's `PACKAGE` argument aliases that public type, avoiding a Signal
  Map-local package signature that would hide `Signal.Package` type
  equalities from callers.
- Migrated public keyed tests, compile-negative fixtures, and the Signal Map
  bench to construct `Signal` explicitly and pass `Signal.Package`. The
  graph-returning private factory remains only under
  `Eta_signal_map_api.Make`, where the keyed-private tests use the internal
  testing seam.
- Verified with:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 4: keyed-bind churn regression

- Added `test_keyed_bind_remove_switch_churn_has_bounded_topology`. The
  generated matrix exercises representative cycle counts through 128, key
  counts through 32, and nested-bind depths through 8. Each cycle stages nested
  bind switches and removes every keyed child in the same stabilization, then
  re-enters the same keys and proves fresh scope identities.
- Every removal and re-entry endpoint checks the committed output, keyed
  pending state, all per-class work-ledger counts, scope validity, and the
  bounded invalid-node tombstone count. Scenario cleanup removes the generated
  children before the next matrix point.
- This is the fifth N2 scenario. Exact tombstone slot-write/eviction counters
  remain part of the diagnostics-storage replacement slice; this regression
  already fixes the frontier-closure and bounded-retention behavior needed for
  that gate.
- Verified with:

```sh
nix develop -c dune runtest test/signal test/signal_map --force
```

## 2026-08-05 - Slice 5: named cutoffs

- Published `Eta_signal.Cutoff` with the five named constructors required by
  the specification: `always`, `never`, `phys_equal`, `of_equal`, and
  `of_compare`. The public cutoff type aliases one private immutable kernel
  representation so public and keyed-package cutoffs have the same identity.
- Replaced the public `?equal` surface with `?cutoff` on sources, derived
  maps, binds, observers, stream bridges, and keyed `data_cutoff`. `const` no
  longer takes a redundant cutoff because a constant has no later candidate.
- Added deterministic contract tests for every constructor, the
  published-then-candidate argument order, and the separate authority of
  producer and observer cutoffs. Registered the new law-bearing prose as
  SC01-SC05 in the executable-law registry and refreshed stale Signal spans
  after the interface insertion.
- Migrated model, keyed, keyed-private, diagnostic, overflow-harness, and law
  call sites. The old raw-function signal APIs were deleted rather than kept
  as wrappers.
- Verified with:

```sh
nix develop -c dune runtest test/signal/contract --force
nix develop -c dune runtest test/signal test/signal_map test/laws --force
nix develop -c dune build @signal-economics
nix develop -c dune build @install
```

- The combined signal, signal-map, kernel, economics, model, and public suites
  completed green. The generated `keyed_mapi_properties.exe` invocation was
  stopped after more than twenty minutes of uninterrupted CPU before it
  printed a final result; this slice remains open, and the complete generated
  law rerun is still required before slice completion.

## 2026-08-05 - Slice 5: balanced reduction

- Deleted `both` from the Signal public surface and kernel implementation.
  Pairing callers now use `map2` directly, which keeps the output cutoff
  explicit instead of hiding it in a convenience wrapper.
- Published `reduce_balanced ?cutoff ~identity ~combine inputs`. Construction
  copies the input array, empty input publishes `identity`, nonempty reduction
  builds a balanced `map2` tree, and the aggregate root is the only cell that
  uses the caller cutoff. Internal cells use `Cutoff.never`, so a changed leaf
  cannot be hidden by physically shared intermediate results.
- Added contract tests proving input-copy and order behavior, exact seven-edge
  initialization for eight inputs, exact three-edge recomputation for one
  changed leaf, internal non-suppression with a physically shared result,
  empty identity publication, and final-cutoff-only suppression.
- Registered the balanced-reduction prose as SC06-SC09 in the executable-law
  registry.
- Verified with:

```sh
nix develop -c dune runtest test/signal/contract --force
nix develop -c dune runtest test/signal test/signal_map --force
nix develop -c dune build @install
```

## 2026-08-05 - Slice 5: labeled bind selector

- Changed public `bind` to the specification's shape:
  `bind ?cutoff ~f source`. The old positional selector path was deleted.
- Migrated Signal, Signal Map, law, model, overflow, negative-boundary, and
  bench call sites to the labeled selector. The overflow harness now exposes
  the same argument order.
- Registered the scalar-algebra API shape as SC10 in the executable-law
  registry.
- Verified with:

```sh
nix develop -c dune build @install
nix develop -c dune runtest test/signal test/signal_map --force
nix develop -c dune build test/laws/keyed_mapi_properties.exe
```

## 2026-08-05 - Slice 5: same-stabilization keyed child repair

- The complete generated law rerun found a real keyed-update ordering bug: when
  a retained child local source changed before the keyed owner accepted new
  data in the same stabilization, the child output could retain its
  generation-local compute memo and publish old data plus new local state.
- `update_child` now stages the accepted data source, marks the child data
  signal dirty, and clears only the generation-local compute memo fields for
  that data signal and child output before recomputing the child. Committed
  generation bookkeeping remains intact, so the same generation can observe
  the newly staged data without duplicating compute accounting.
- Added the deterministic public regression
  `keyed_mapi_child_reads_accepted_data_same_stabilization`, which changes a
  child-local source and accepted keyed data before one `stabilize` and
  requires the coalesced final value.
- Removed the custom keyed-property shrinker. It explored tens of millions of
  shrink steps after this failure and delayed the counterexample; the law now
  reports the generated sample directly while preserving the same generated
  coverage.
- Verified with:

```sh
nix develop -c dune runtest test/signal_map/keyed test/laws --force
nix develop -c dune runtest test/signal test/signal_map test/laws --force
nix develop -c dune build @install @signal-economics
```

- All targeted Signal, Signal Map, generated-law, install, and economics gates
  completed green, including
  `keyed_mapi_retained_child_preserves_local_state` and
  `keyed_mapi_child_reads_accepted_data_same_stabilization` over 1000 generated
  cases each.
- `@doc` is not a current slice gate: the OxCaml switch has no compatible
  `odoc` package, while a mainline `odoc` attempt generated the Signal docs and
  then failed in pre-existing non-Signal sources that use `effect` as an
  identifier. The Signal documentation emitted only existing ambiguity
  warnings.

## 2026-08-06 - Slice 6 checkpoint: topological observer delivery engine

- Replaced the O(n^2) pairwise observer comparator with one deterministic
  total topological plan. `Eta_signal_observer_plan` (transaction engine)
  builds the candidate union closure, runs Kahn-style traversal with an
  array-backed binary min-heap, and owns candidate dedupe by observer
  identity. Deleted `Graph.compare_order`, `Make_order`, `ORDER_NODE`,
  `order_ops`, and `Id.compare_observer` in the same slice.
- Replaced the delivery registry scan with an intrusive doubly-linked
  candidate work set (`obs_candidate_previous/next` +
  `observer_candidate_head`). Candidate admission on signal change and
  observer registration is O(1); both delivery planning and atomic-pass
  rollback iterate the candidate set instead of `t.observers`.
- Candidate flags survive planning and collection until commit succeeds.
  `delivery_event_source` gained `finish_collection`, invoked only after
  `mark_pending` succeeds inside the sealed commit plan; rollback leaves
  candidates intact so failed commits preserve retryable delivery work.
  Work-ledger admit/release pairs the link transition, never double
  releasing on acknowledge.
- Moved the fail-fast sequential delivery runner into
  `Eta_signal_observer_delivery` (`create`/`run`/`run_claimed`) so the
  ownership table matches the specification: delivery termination lives in
  the execution engine, not the kernel.
- Exactly-once finish: `Snapshot.clear_pending_delivery` runs before the
  `on_finish` hook, disposal/invalidation skip collected callbacks, and the
  public `Observer.observe` gained `?on_finish`. Kernel tests prove
  exactly-once finish on both disposal and dynamic-scope invalidation.
- Wired `Eta_signal_observer_plan` and `Eta_signal_observer_delivery`
  counters into the kernel `Extension` (snapshots plus reset). The kernel
  counter test proves the planner visits only union members (no pairwise
  reachability) for an unrelated-observer scenario.
- Contract tests now cover all six registration orders of the A/C/B
  counterexample and the dependent/independent scenario. Ready unrelated
  groups select by smallest observer identity, then signal identity;
  expectations are explicit per registration order.
- LAWS.md gained SC11-SC13 (exactly-once finish, pending-clear/disposal
  skip, deterministic total topological delivery order) with the normative
  source span in `eta_signal.mli` observer docs.
- Verified with:

```sh
nix develop -c dune build @install
nix develop -c dune runtest test/signal test/signal_map test/laws --force
nix develop -c dune build @signal-economics
nix develop -c dune runtest test/signal/economics --force
```

- Remaining slice-6 work: align the public `Observer.observe` signature
  with specification 8.1 (single `?on_finish`, labeled optional
  `?on_update`, delete `Observer.unsafe_read_exn`), then final gates and
  slice completion.

## 2026-08-06 - Slice 6: public observer API matches specification 8.1

- `Observer.observe` now has the specification shape:
  `?cutoff -> ?on_finish:(observer_finish -> unit) -> ?on_update:(...) ->
  'a signal -> ...`. `on_finish` is one hook instead of a list, and the
  update callback is a labeled optional. An observer without `?on_update`
  installs a no-op callback, keeping candidate admission, publication,
  delivery accounting, and exactly-once finish uniform while still owning
  demand and current committed state (specification 8.1).
- Deleted public `Observer.unsafe_read_exn` per resolved issue 13. The
  deletion orphaned the private chain `Observer_lifecycle.unsafe_read_value_exn`
  and `Value.unsafe_read_exn`, which are removed in the same change. Typed
  `Observer.read` already covers every invalid state (`Uninitialized`,
  `Disposed`, `Invalid_scope`), so no probe replacement was needed.
- Migrated all 300+ call sites in lib and test code to the labeled form
  `observe signal ~on_update:callback` (labeled arguments commute, so no
  site needed argument reordering). The overflow harness signature and
  implementation alias were updated to the new shape.
- Replaced the contract test `observer unsafe read reports invalid state`
  with `observer read reports invalid state` (typed `read` over
  uninitialized, stabilized, and disposed states) and added
  `observer without on_update owns demand`, which proves a demand-only
  observer initializes and keeps recomputing across source updates.
- LAWS.md: corrected SC11-SC13 source spans after the doc edit and added
  SC14 for the demand-only claim with its named contract test. Updated one
  stale PRD coverage row whose test reference was renamed by this change;
  the PRD's overall "active implementation target" status predates the V1
  specification and is slice-11 documentation debt.
- Verified with:

```sh
nix develop -c dune build @install @signal-economics
nix develop -c dune runtest test/signal test/signal_map test/laws --force
nix develop -c dune runtest test/signal/economics --force
```

- `test/signal_jsoo` call sites were migrated but remain unverified on this
  track; the OxCaml switch does not build js_of_ocaml targets. Mainline
  verification is scheduled in slice 12.

## 2026-08-06 - Slice 7a: delete Time.step and Time.step_replay

- Specification 9 deletes `Time.step`, `Time.step_replay`, and polling
  arguments on one-shot timers. This increment removes the step APIs and
  every path that only they could reach.
- Deleted the public `Time.step`/`Time.step_replay` declarations and docs,
  the kernel constructors, and the kernel helper
  `timer_run_user_update_if_continuing` (with its orphaned
  `timer_continue_after_update`). Only step constructors could run user
  code inside the timer daemon, so the demand-drop re-check window went
  with them.
- Deleted `Timer_policy.step_source_policy` and
  `step_replay_source_policy`. `Catch_up_every_cadence` lost its last
  producer, so the constructor, the daemon `update_batch` machinery
  (batch size 64, inter-batch `Effect.yield`), and the policy `update_batch`
  type and functions are deleted too. The daemon now applies at most one
  source update per wake for every remaining constructor; interval
  catch-up stays arithmetic and saturated.
- Deleted the 14 step-focused tests whose claims only existed through the
  step APIs. The surviving claims keep independent coverage: interval
  catch-up without daemon progress (`time interval catches up
  arithmetically without daemon yield`, `time active interval refreshes
  before daemon runs`), saturated coalescing, and runtime-mismatch timer
  validation (interval case).
- Stale pre-V1 PRD and research documents still mention `Time.step`;
  their wholesale drift (including the "active implementation target"
  status in `docs/prds/0002-eta-signal-frp.md`) is slice-11 documentation
  debt, not something to patch row by row in historical documents.
- Verified with:

```sh
nix develop -c dune build @install @signal-economics
nix develop -c dune runtest test/signal test/signal_map test/laws --force
nix develop -c dune runtest test/signal/economics --force
```

- Remaining slice-7 work: delete `~every` polling arguments and the
  `unit` argument on `now` (one-shot timers schedule one exact deadline),
  then replace the per-commit `timer_nodes`/reachability scans with queued
  timer reconciliation and generation fencing.

## 2026-08-06 - Slice 7b: one-shot timers schedule one exact deadline

- Deleted the `~every` polling arguments from `Time.deadline` and
  `Time.after` and the `unit` argument from `Time.now`, matching
  specification 9. One-shot timers no longer validate or carry a polling
  cadence; `after` still validates a positive duration and deadline
  provenance/overflow checks are unchanged.
- Added `Timer_policy.schedule = Periodic of int | One_shot of int` and
  threaded it through the daemon (`Timer.start`, `run_loop`,
  `start_daemon`, `create_daemon_node`) in place of a bare `interval_ms`.
  `initial_next_due_ms` returns the exact deadline for one-shot timers;
  `daemon_wake_plan` fires at most one update when the clock reaches the
  deadline and never advances the due point. Periodic timers keep the
  existing missed-cadence arithmetic. The on-demand refresh path was
  already deadline-exact and is unchanged.
- Discriminating evidence: `time after daemon sleeps until exact deadline`
  proves the daemon requests exactly one sleep across its whole lifecycle,
  does not poll before the deadline, and fires once when the clock crosses
  it. Policy tests gained one-shot wake-plan and initial-due cases.
- Deleted the now-meaningless invalid-cadence cases for one-shot timers
  (`invalid deadline cadence`, `invalid after interval`) and simplified
  their scaffolding. Migrated all 36 call sites in eight test files.
- LAWS.md gained SC15 (one exact deadline, no cadence polling) with the
  new discriminating tests as named evidence.
- Verified with:

```sh
nix develop -c dune build @install @signal-economics
nix develop -c dune runtest test/signal test/signal_map test/laws --force
nix develop -c dune runtest test/signal/economics --force
```

- Remaining slice-7 work: replace the per-commit `timer_nodes` and
  reachability scans (`collect_current_necessary_timers`,
  `collect_post_commit_necessary_timers`) with queued timer reconciliation
  and generation fencing.

## 2026-08-06 - Slice 7c design: queued timer reconciliation (mapped)

- Scans to replace, all in the kernel: (1) `preflight_commit_staging`
  diffs `collect_post_commit_necessary_timers` (full reachability from
  observer demand roots) against `collect_current_necessary_timers`
  (`timer_nodes` Hashtbl scan); (2) the effect path `refresh_timer_demand`
  -> `timer_demand_plan_unlocked` -> `Timer.node_demand_plan` re-derives
  necessity per timer via a `timer_nodes` lookup scan; (3)
  `begin_stabilize` iterates all `timer_nodes` with a `demand > 0` filter
  to schedule timer refreshes.
- Key enabler: every demand change funnels through
  `Demand.adjust_many`, and `on_boundary` fires exactly once per
  necessity crossing after each successful adjustment and never on a
  failed one (overflow/underflow restores counts before boundaries are
  delivered). Boundary effects never roll back: demand mutations happen
  outside stabilization (observer register/dispose) or inside the sealed
  total commit (bind/keyed topology). The kernel boundary hook already
  admits/releases `Work.Timer_reconciliation` on timer crossings.
- Design: each timer signal carries a physical `desired_necessary` flag
  flipped by the boundary hook, plus an intrusive reconciliation link
  (observer-candidate pattern from slice 6). The sealed commit preflight
  drains the queue (preflight start/stop by desired vs actual timer state,
  generation fencing), staging rollback re-links drained timers, the
  commit seals the action list, and post-commit effects apply it. The
  standalone dispose path drains the same queue through
  `refresh_timer_demand` with no scan. The `begin_stabilize` refresh scan
  becomes an intrusive demanded-timer set linked/unlinked at the same
  boundary points.
- The `Timer.node_demand_plan ~is_necessary` scan protocol and the two
  collect_*_necessary_timers functions are deleted once the queue serves
  both drains.

## 2026-08-06 - Slice 7c: queued timer reconciliation (implemented)

- Replaced every per-commit timer scan with boundary-driven queued
  reconciliation:
  - Each timer signal carries an intrusive reconcile link
    (`timer_reconcile_linked/previous/next` + a token bumped on every
    boundary). The `Demand.adjust_many` `on_boundary` hook links timer
    signals on every necessity crossing; linking is guarded by
    `timer_nodes` membership so invalidated timers can never re-enter
    the queue (invalidation already unlinks and stops via hooks).
  - The queue is a touched set only; necessity is re-derived from live
    `signal.demand` at drain time, which keeps the design staging-
    rollback safe (rollback restores demand without firing boundaries,
    but the still-linked timers re-derive the restored direction).
  - `begin_stabilize` refresh scheduling now iterates the incrementally
    maintained `necessary_nodes` set (timer + `timer_nodes` membership
    filters) instead of scanning all `timer_nodes` with a demand filter.
  - `preflight_commit_staging` drains the queue non-consuming
    (`preflight_timer_start/stop` are pure capacity checks) and deletes
    `collect_current_necessary_timers`,
    `collect_post_commit_necessary_timers`,
    `preflight_post_commit_timer_starts/stops`, and the orphaned
    `Graph.timer_demand_source`/`timer_demand`/`timer_demand_plan`/
    `post_commit_necessary_timers` family plus `graph_reachable_plan`.
  - Effect path: `timer_demand_plan_unlocked` snapshots the queue
    (token-tagged) and unions it with necessary timers (runtime-contract
    validation must cover every necessary timer even without a pending
    transition; `classify_demand` validates necessary resources).
    `refresh_timer_demand` unlinks snapshot tokens only on success;
    failures leave timers linked for the next retry (spec: a failed
    start leaves a queued lifecycle mismatch; a later graph effect
    retries it). The token is bumped on every boundary so a boundary
    mid-refresh keeps the timer queued.
  - Async lifecycle mismatches (daemon error exits, failed starts) never
    fire a boundary, so `Timer.daemon_context` gained
    `on_lifecycle_mismatch`, invoked from `cleanup_after_exit` and
    `cleanup_failed_start` on `Daemon_error` exits only; the kernel
    re-links the timer's signal. Clean starts/stops do not fire it.
- Bind-switch subtlety: bind lifecycle (attach/detach + demand cascade)
  applies at commit, after preflight, so the queue cannot see staged
  switches at preflight time. `preflight_staged_bind_timers` reserves
  capacity with two branch-bounded traversals per staged bind switch
  with a demanded owner: starts follow the staged (effective) branch,
  stops follow the current branch for timers whose demand crosses to
  zero. Same-inner re-stage is skipped (net-zero demand). This replaces
  the old whole-graph post-commit reachability with work proportional
  to the switched branches; steady-state commits with no staged binds
  do no traversal.
  - Documented corner: a timer at `max_int` generation behind nested
    staged binds where the activating demand arrives from an outer
    switch in the same commit can surface the generation overflow in
    the effect phase rather than at precommit; the failure is still
    loud and typed, one phase later. Single-level binds (the contract
    tests) stay exact at precommit.
- Evidence:
  - `timer reconciliation is boundary driven` (kernel extension):
    untouched stabilize = 0 timer desired-state transitions and 0
    reconciliation work; registration = exactly 1; timer tick = no new
    transition; disposal = exactly 1 more; work released after demand
    loss. `Eta_signal_demand.note_timer_desired_state_transition` is
    now wired into the kernel boundary hook (was counter-test-only).
  - `failed start reports lifecycle mismatch` and
    `clean start skips lifecycle mismatch` (timer demand suite):
    daemon-context hook fires exactly on `Daemon_error` start/exit.
  - Overflow contract preserved: `time timer start overflow is
    precommit failure` and `external timer stop overflow is precommit
    failure` both pass (these pinned the staged-bind preflight
    traversals).
  - Runtime-mismatch suite (`timer runtime mismatch on observe`,
    `mixed runtime timer mismatch recovery`,
    `dispose reports timer runtime mismatch`) passes with the
    queued-union-necessary plan.
- Verified with:

```sh
nix develop -c dune build @install @signal-economics
nix develop -c dune runtest test/signal test/signal_map test/laws --force
nix develop -c dune runtest --force
```

- Full suite: 76 test executables green.
