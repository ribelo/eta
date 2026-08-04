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
