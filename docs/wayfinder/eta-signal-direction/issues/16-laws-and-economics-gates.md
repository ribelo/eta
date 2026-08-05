# Laws and economics gates

Type: grilling
Status: resolved
Blocked by: 09, 10, 11, 12, 13, 14, 15

## Question

Which executable laws and deterministic economics gates prove the final Eta
Signal direction?

Define one named observation boundary and generated class for each behavioral
law. Define operation-count gates for quiescence, narrow changes, dynamic
switches, keyed changes, observer delivery, timers, and wide fan-in. Include
cleanup, tombstone-index work, and empty-fiber-census requirements where no
background work is valid.

Resolve F3 and F13 for the final interface. Reuse authoritative tests when they
already prove the exact claim. Do not use wall time as a correctness gate.

## Answer

The final direction uses generated behavioral laws, fixed adversarial
regressions, and deterministic operation-count gates. Wall time remains
benchmark output only.

Every new correctness defect gets a deterministic regression before its fix
merges. The regression must fail against the defective behavior and observe the
smallest stable public or invariant-owner boundary.

If later work deletes that implementation, it must replace the regression with
a contract-level test for the same defect class. Random stress without a
reproducible seed and counterexample is supplementary evidence.

### Gate groups

Add these durable gate groups:

| Gate | Primary location | Purpose |
|---|---|---|
| Generated Signal laws | `test/laws/signal_properties.ml` | Scalar, transaction, observer, timer, and diagnostic laws |
| Atomic-pass regressions | `test/signal/atomic_pass/` | N1, N5, cleanup, and retry boundaries |
| Mixed keyed-bind regressions | `test/signal_map/keyed/` | The five N2 scenarios |
| Stream laws | `test/signal_stream/` | Queue, acknowledgement, finish, and cross-domain laws |
| Deterministic economics | `test/signal/economics/` | Private operation counts and asymptotic controls |

Every effectful property uses fiber accounting. A case with no legitimate
background work ends with an available empty fiber census.

A timer or stream case can contain live background work during its scenario.
After disposal or finish, it must also end with an available empty census.

Every generated failure prints its seed, generated class, operation tape,
expected observation, actual observation, and private census.

### F3 and the law registry

F3 is confirmed. The law registry contains only blanket Signal debt
`D-E22-004`. The current state is explicit, but it is not claim-complete.

Do not register the current interface wholesale. Tickets 12 through 15 delete
or replace major parts of that interface.

The implementation must replace `D-E22-004` with one row for each normative
claim in the final Signal, Signal Stream, and changed Signal Map interfaces.
Each row must contain an exact source span and one named executable.

No final changed interface can use new dated debt. Existing authoritative tests
enter the registry by exact name. The implementation adds a property only when
existing evidence does not prove the complete claim.

Unchanged persistent-map, representation, and package laws keep their current
rows and property names. Changed stable-family rows move to the final
`Signal.Package` adapter and typed probes.

Delete registry rows for deleted APIs in the same slice that deletes each API.
These APIs include:

- `Owner_transaction`
- raw `?equal` arguments and `const ?equal`
- `both`
- `Observer.unsafe_read_exn`
- mandatory observer callbacks without a finish hook
- core `Signal.Stream`
- `Time.step` and `Time.step_replay`
- polling arguments on one-shot deadlines
- the second Signal Map graph factory
- unsafe `Obj` testing tokens

### Behavioral law matrix

Each row defines one named observation boundary and one generated class. The
property name is exact.

| Property | Observation boundary | Generated class and discriminator |
|---|---|---|
| `signal cutoff constructors observe published then candidate` | Ordered cutoff calls, publication, downstream calls, updates, and `Observer.read` | Shared and distinct values across all five cutoff constructors. Non-symmetric predicates detect argument reversal. Both suppression results occur. |
| `signal producer and observer cutoffs have distinct authority` | Producer calls, observer calls, committed reads, and callback trace | Independent producer and observer cutoff choices. Cases include producer-only and observer-only suppression. `Initialized` always occurs. |
| `signal explicit stabilization publishes only final accepted source writes` | `Var.value`, committed reads, callbacks, and commit count | Zero through eight accepted writes before stabilization. The source read changes immediately, while the committed read changes once after explicit stabilization. |
| `signal update_effect publishes only a successful returned value` | Effect exit, `Var.value`, committed read, and update callback count | Success, typed failure, defect, interruption, and reentrant update. Only success changes the accepted source value. |
| `signal static dags publish glitch-free final snapshots` | Committed reads, callback snapshots, and user-function counts | Generated acyclic static graphs with diamonds, repeated edges, arities one through nine, `all`, batched sets, and cutoff-stopped branches. |
| `signal static combinators preserve argument order and final candidates` | Constructor call log, final value, and update count | Arity one through nine and lists. The lists include empty lists and repeated signals. Distinct argument values detect reordering. |
| `signal bind switches only after selector publication` | Selector cutoff calls, builder calls, scope identities, and output trace | Suppressed and accepted selector candidates across distinct branches. Every run contains both outcomes. |
| `signal bind-only cascades converge in one stabilization` | Final read, builder order, scope states, and pending-work probe | Bind depth one through 32. Each run switches at least two levels and retires an old branch. |
| `signal failed bind planning preserves the branch and retries` | Exit, old branch identity, committed value, topology, and retry result | Selector defects, validation failures, and later valid candidates. Every failure class reaches a successful retry. |
| `signal callback sets wait for the next explicit stabilization` | `Var.value`, callback-local reads, and traces across two stabilizations | One through eight callback sets with repeated values and cutoffs. The accepted source differs from the active committed value. |
| `signal reduce_balanced matches an ordered associative fold` | Observer value, complete combine trace, and copied input topology | Empty, singleton, power-of-two, and irregular arrays. Generated monoids include addition, XOR, maximum, and ordered list concatenation. |
| `signal reduce_balanced copies its input array` | Topology and output after caller array mutation | Generated arrays mutate every position after construction. Production output remains based on the construction-time copy. |
| `signal prospective cycles reject before publication` | Typed exit, edge inventory, reads, scope state, and recovery | Self cycles, mutual bind cycles, stable-family child cycles, and acyclic controls over one through 32 nodes. |
| `signal graph operations enforce owner domain and runtime provenance` | Synchronous exception, effect exit, committed state, and both graph states | Owner and foreign domains, two graph instances, and two runtimes. Wrong-domain and wrong-runtime operations change neither graph. |
| `signal diagnostics are committed value-free and noninterfering` | `stats`, DOT, subsequent operation traces, counters, and fiber census | Valid and invalid scalar, stable-family, observer, and timer states with sentinel values. Runs with and without diagnostic reads remain equivalent. |

The reduction property executes both association forms, a sequential ordered
fold, and the production reduction. It does not claim that Eta can validate an
arbitrary caller function.

The static DAG property resolves S1 and bounded S3. Its private count requires
one computation for each necessary stale node and zero computations beyond a
cutoff-stopped frontier.

The bind properties resolve S4, bind-only S6, and pre-commit S7. The cycle
property retains S17 with the Ticket 10 prospective-validation explanation.

### Atomic-pass laws

Add one generated planning-fault property:

`signal generated planning faults roll back exactly and retry with empty census`

Its observation boundary contains the exit, phase, committed values, topology,
demand, observer cursor, cleanup ledger, pending work, and fiber census.

The generated class crosses static, bind, stable-family, and mixed graphs with
these fault slots:

1. `Before_phase_install`
2. `After_phase_install`
3. `After_dynamic_discovery`
4. `After_frontier_freeze`
5. `After_discard_partition`
6. `After_prospective_validation`
7. `Before_plan_seal`
8. `Before_total_commit`

Each case preserves the committed snapshot and topology. It clears provisional
state, runs every required cleanup once, returns to `Idle`, and then retries
successfully.

Add one generated post-commit property:

`signal generated postcommit exits preserve commit and retry delivery`

Its observation boundary contains the exit, commit and rollback counts,
committed state, phase, cleanup ledger, delivery cursor, retry trace, and fiber
census.

Its generated class crosses typed callback failure, callback defect,
interruption, timer lifecycle failure, and cleanup failure after total commit.

Each case advances the commit count once and never calls rollback. Committed
state stays visible. Mandatory cleanup drains once. A later stabilization
retries only pending active deliveries.

Keep a direct structural test named
`test_total_commit_interprets_only_prepared_writes`. It proves that commit
accepts only a sealed plan and invokes no validation, user callback, or fault
hook.

### N1 regression disposition

Physical transaction identity deletes transaction-ID and stabilization-token
overflow. Remove those harness branches. Do not preserve a fault for an
allocator that no longer exists.

Add `test_atomic_phase_entry_allocation_defect_preserves_idle_and_retryable_work`.
The fault occurs after workspace allocation and before the single phase
assignment.

The test observes the original defect, an exact `Idle` phase, no installed
transaction, unchanged committed state, queued source work, successful retry,
one publication, and an empty fiber census.

Remaining checked counters keep a generated regression:

`signal remaining checked counter overflow rejects before publication and retries`

Its observation boundary contains the synchronous constructor result or
effectful exit, phase, committed state, pending work, target counter, retry
trace, `stats` result, and fiber census.

Its target class contains the signal, scope, variable, and observer ID
allocators. It also contains demand counts and timer generations. The final
engine contains no dependency-version counter.

A typed private probe injects each boundary and restores it for retry.

Signal and variable constructor targets raise
`Graph_error (Counter_overflow name)`. Scope, observer, demand, and timer targets
return `Counter_overflow name` through their Eta error channel.

Each target publishes nothing, preserves or returns to `Idle`, and succeeds
after reset. Public diagnostic saturation remains nonfatal to graph behavior and
makes the next `stats` call report `Counter_overflow`.

N01-032 does not apply. The final design contains no shared global allocator.
Two independent graph instances still run concurrently as a graph-isolation
control, not as an allocator regression.

### N2 regression set

Use final graph-branded stable-family probes. DOT and unsafe object casts are
not primary oracles.

| Exact test | Required discriminator |
|---|---|
| `test_keyed_removal_discards_nested_bind_switch_to_top_scope` | Removal commits at the family owner. The nested switch is discarded. No top-scope signal keeps an edge to the invalid bind. |
| `test_keyed_removal_invalidates_nested_bind_provisional_scope` | A new child-scope branch becomes discarded once. Its hook runs once, and it never enters topology or demand. |
| `test_keyed_removal_clears_nested_bind_pending_state` | At least two nested bind levels force frontier closure. Every owned operation, staged cell, provisional scope, and pending plan is cleared. |
| `test_keyed_bind_remove_switch_churn_has_bounded_topology` | Generated add, remove, switch, and re-entry cycles return to the live baseline. Identities are fresh, and tombstones stay bounded. |
| `test_keyed_removal_nested_bind_topology_survives_callback_defect` | A callback defect after commit cannot restore retired topology. Only observer delivery remains pending. |

Every test inspects exact role identities, edge slots, scope states, cleanup
counts, pending work, and the final fiber census.

The churn case generates cycle count `c` from 1 through 128, key count `k` from
1 through 32, and bind depth `d` from 1 through 8.

Its constructor manifest records baseline live nodes `B`, invalidations per
cycle `I`, and provisional resources per cycle `P`. Each removal endpoint has
exactly `B` live nodes and zero pending operations.

After `c` cycles, slot writes equal `c * I`. Retained tombstones equal
`min(c * I, 1024)`. Evictions equal `max(0, c * I - 1024)`. Cleanup terminal
transitions equal registrations and equal `c * P`.

The current `keyed_mapi_outer_removal_excludes_nested_plan` test remains useful
for its own nesting direction. It does not prove the mixed N2 counterexample.

### Observer laws

Add these generated properties:

| Property | Observation boundary | Generated class |
|---|---|---|
| `signal observer initialization and read follow committed state` | Update trace, `Observer.read` exit, recompute count, and lifecycle state | Registration before and after writes, explicit stabilization, disposal, and invalid scope. It covers no-current, initialized, changed, and terminal reads. |
| `signal observer plans are total topological across registration permutations` | Exact callback identity sequence and fail-fast stop | DAGs with chains, diamonds, duplicate observers, unrelated groups, bind switches, and the `A < C < B` counterexample. Small graphs run all registration permutations. |
| `signal observer callbacks share one committed snapshot` | Reads captured in callbacks and the next stabilization | An early callback changes every later source. All current callbacks still read one committed snapshot. |
| `signal delivery failures retain exactly the unacknowledged suffix` | Attempts, acknowledgements, cursor state, reads, and exit | Three or more candidates with failure at each position. Failure classes include typed error, defect, and interruption. |
| `signal delivery retry coalesces from last acknowledged to latest current` | Retry update and callback count | Intermediate failures, newer commits, return to the baseline, direct acknowledgement, and terminal-drop acknowledgement. |
| `signal observer finish runs once and clears delivery` | Finish trace, update trace, read exit, demand, and cursor | Disposal and invalid scope across idle, pending, and running states. Repeated disposal and a finish-hook defect are required. |
| `signal observer finish races are lane-linearized` | Lane mutation order and terminal cursor | Exhaustive permutations of acknowledgement, finish, and failure release. A running callback can finish but cannot restore activity. |

Existing observer tests can enter these registry rows as fixed adversarial
witnesses. They do not replace the generated permutation and race classes.

### Timer laws

Register surviving exact test-clock tests after API migration. Delete all
`step` and `step_replay` tests.

Add:

`signal generated timer demand fences generations and retries lifecycle`

Its boundary includes the desired state, actual state, generation, daemon
count, publication trace, test-clock sleepers, pending work, and fiber census.

The generated commands add and remove demand, wake current and stale
generations, inject start and stop failures, advance the clock, stabilize, and
dispose.

The property covers these branches:

- zero-to-one demand starts once
- nonzero demand changes start nothing
- one-to-zero demand fences generation before cancellation
- a stale generation publishes nothing
- a failed start leaves a queued mismatch
- a later graph effect retries the mismatch
- a daemon wake queues work and never calls `stabilize`
- one-shot timers use one exact deadline
- interval catch-up uses one arithmetic update and saturates
- teardown leaves no active timer, sleeper, or fiber

Runtime provenance, past deadlines, invalid intervals, and deadline overflow
use these generated properties:

| Property | Observation boundary | Generated class |
|---|---|---|
| `signal time values enforce runtime provenance and arithmetic bounds` | Result, typed exit, both runtime states, and test clocks | Two runtimes, past and future timestamps, positive and nonpositive durations, and values adjacent to integer overflow. |
| `signal one-shot timers use one exact deadline` | Test-clock sleeper deadlines, signal value, daemon count, and fiber census | `deadline` and `after` across positive durations and cancellation before, at, and after the deadline. |
| `signal interval coalesces missed cadence arithmetically` | Clock reads, wake count, queued source work, committed value, and fiber census | Zero, one, and many missed periods, plus saturation-adjacent interval values. Every case calls `stabilize` explicitly. |

### Stream laws

Move the surviving bridge tests to `test/signal_stream/`. Add:

`signal stream generated outcomes and acknowledgements match the queue model`

The boundary contains stream values, dropped updates, queue state, delivery
acknowledgements, observer state, finish reason, and fiber census.

Generate positive capacities, bursts, takes, interruption points, disposal,
invalid scope, and a raising drop hook. Every offered update gets exactly one
sent-or-newest-dropped outcome and exactly one acknowledgement.

The property also proves nonblocking publication, no retry duplicate, clean
drain on disposal, `Invalid_scope` finish, and cross-domain stream consumption.
The observer handle remains owner-domain-only.

Add:

`signal stream capacity validates the default and every nonpositive value`

Its observation boundary contains the construction exit, offer outcomes, queue
contents, drop trace, observer demand, and fiber census.

The generated class contains every integer from -100 through zero and positive
capacities 1 through 32. Nonpositive values return `Invalid_capacity` and create
no observer or queue.

The default case offers 1,025 captured events without consumption. Exactly 1,024
events enter the queue, and the last event has one newest-drop outcome.

Add:

`signal stream with_observed disposes once across every exit kind`

The body exits through success, typed failure, defect, and cancellation. Each
case preserves the body exit, disposes once, and closes the queue gracefully.
The generated body consumes a prefix before exit. Values in that prefix keep
their order.

The property does not require consumption after the body returns. Teardown still
ends with an empty census.

### Private work counters

Counters stay at their invariant owners. `Eta_signal_test_probe` exposes
graph-branded lane-protected reset and snapshot operations. Those probe
operations do not increment counters.

Each counter is saturating and cannot change graph behavior. A saturated test
counter makes its gate fail. Counter groups overlap and never form one total.

| Owner | Exact counter boundaries |
|---|---|
| `Eta_signal_atomic_pass` | phase entries, commits, rollback calls, and returns to `Idle` |
| `Eta_signal_commit_plan` | sealed plans, prepared writes, applied writes, cycle nodes, and cycle edges |
| `Eta_signal_work` | admission checks, quiescent returns, and work-class zero crossings |
| `Eta_signal_scheduler` | admissions, claims, dependency-edge visits, propagation-edge visits, node evaluations, and cutoff calls |
| `Eta_signal_demand` | reference operations, zero boundaries, dependency-edge visits, and timer desired-state transitions |
| `Eta_signal_topology` | static inserts, dynamic inserts, indexed removals, slot repairs, invalidated nodes, and adjacency search steps |
| `Eta_signal_stable_family_plan` | input comparisons, diff events, selected-child visits, provisional additions, commits, and discards |
| `Eta_signal_observer_plan` | candidate visits, union node and edge visits, ready pushes, ready pops, ready comparisons, and pairwise search visits |
| `Eta_signal_observer_delivery` | lifecycle checks, callback attempts, acknowledgement attempts and successes, releases, and terminal skips |
| `Eta_signal_timer` | reconcile claims, starts, stops, cancellations, wakes, stale wakes, and cleanup claims |
| `Eta_signal_cleanup` | resource registrations, terminal transitions, hook attempts, hook completions, and duplicate-transition rejections |
| `Eta_signal_tombstone_index` | slot writes, evictions, iteration visits, and duplicate scan steps |

Scheduler node evaluations and cutoff calls cover pure graph callbacks only.
Observer callbacks are counted only by `Eta_signal_observer_delivery`.

`adjacency_search_steps`, `pairwise_search_visits`, and
`duplicate_scan_steps` must stay zero in the final engine. These negative
counters detect hidden list scans that logical operation counts cannot expose.

### Economics measurement protocol

Every economics case follows this protocol:

1. Create a fresh Signal functor instance and runtime.
2. Construct and initialize through public APIs.
3. Assert the intended graph size with a typed probe.
4. Reset counters immediately before one measured public operation tape.
5. Run that tape once.
6. Read counters under the graph lane.
7. Assert the public result against an independent fixture manifest.
8. Dispose all observers and timers.
9. Assert an available empty fiber census.

Setup, initial stabilization, observer registration, probe reads, and teardown
stay outside the interval unless one is the measured operation.

The graph-size series is exactly 1,000, 10,000, and 100,000. Public `const`
ballast reaches each size without changing the active fixture.

An independent fixture manifest records each expected operation identity,
counter owner, edge multiplicity, and order during construction. It also records
the affected node and edge sets.

Expected counts are cardinalities of the manifest entries for each counter. The
manifest does not read or derive data from measured counters.

### Economics gates

The narrow fixture has one source, ten unary maps, and one endpoint observer.
Its manifest contains 11 scheduler claims, ten dependency edges, ten propagation
edges, ten node evaluations, and ten cutoff calls.

For graph size `N`, the half-graph fixture uses
`m = floor((N - 1) / 2)` observed unary maps on one changed source. Its manifest
contains `m + 1` claims and `m` entries for every map or edge counter.

The nested-bind fixture uses depths 1, 8, and 64 at each graph size. Its manifest
names every retired and installed scope, edge, demand transition, plan, and
cleanup resource.

The keyed-child fixture uses 1,000, 10,000, and 100,000 keys. It changes one
child-local source without an input edit.

Observer controls use candidate counts 1, 32, and 1,024. A separate control uses
eight fixed candidates with 1,000, 10,000, and 100,000 unrelated observers.

`Eta_signal_observer_plan` uses an array-backed binary min-heap for ready groups.
A push uses at most one comparison per level. A pop uses at most two comparisons
per level.

| Exact gate | Deterministic requirement |
|---|---|
| `signal work quiescent is constant` | The tape gives one admission check and one quiescent return. Every phase, scheduler, demand, topology, observer, timer, cleanup, and commit counter is zero. |
| `signal work narrow frontier is proportional` | The measured vector equals the declared narrow manifest at every `N`. Ballast changes no counter. |
| `signal work half graph is proportional` | The measured vector equals the `m` formulas above. Observer candidates, attempts, and acknowledgements each equal `m`. |
| `signal work nested bind switch is frontier bounded` | The measured vector equals the depth manifest at depths 1, 8, and 64. Ballast changes no counter. Search-step counters stay zero. |
| `signal work keyed child change visits one child` | The stable-family counters report one selected child, zero input comparisons, zero diff events, and zero topology edits at each key count. |
| `signal observer planning visits only the candidate union` | Candidate and union counts equal the manifest. Pushes and pops equal candidate groups. Ready comparisons stay within `4 * C * ceil(log2(C + 1))`. Pairwise visits stay zero. |
| `signal observer planning ignores unrelated observers` | The complete counter vector for eight candidates is identical at all unrelated-observer sizes. |
| `signal timer reconciliation visits queued items only` | One mismatch gives one reconcile claim. A linear control with 1, 32, and 1,024 mismatches gives that exact claim count. Timer ballast adds no visit. |
| `signal wide all attachment is linear` | Construction over `n` distinct signals gives exactly `n` static inserts and zero adjacency search steps. |
| `signal wide parent invalidation is linear` | The marginal result against a zero-width control gives exactly `n` indexed removals, at most `n` slot repairs, and zero adjacency searches. |
| `signal keyed removals are linear` | Removal of `k` children gives exactly `k` indexed removals and cleanup transitions, at most `k` slot repairs, and zero adjacency searches. |
| `signal reduce_balanced leaf change is logarithmic` | One interval measures initial construction. A second reset measures one leaf change. Powers of two give `n - 1` and `log2 n` combine calls. |
| `signal tombstone insertion is constant` | Each invalidation writes one slot. Evictions equal `max(0, count - 1024)`. Duplicate scan steps stay zero. |

The wide gates use 1,000, 10,000, and 100,000 edges. The reduction gate also
uses powers of two through 131,072 for exact path counts.

The irregular reduction control uses lengths through 100,000. Its changed-leaf
count cannot exceed `ceil(log2(n + 1))`.

The keyed-removal gate uses `k` values 1, 1,000, 10,000, and 100,000.

The tombstone gate uses 0, 1, 1,023, 1,024, 1,025, and 100,000 insertions. The
retained count is `min(count, 1024)`. Iteration visits that exact count in
newest-first order.

The public invalidation fixture also requires:

```text
tombstone.slot_writes = topology.invalidated_nodes
```

This equality proves the connection between one-way node lifetime and one index
write.

### Reuse and replacement

Register existing tests only when their exact observation matches a final row.
These exact tests are candidate fixed witnesses after API migration:

- `test_explicit_stabilization_boundary`
- `test_observer_read_does_not_force_recompute`
- `test_diamond_trace_matches_model`
- `test_observer_callbacks_read_consistent_published_snapshot`
- `test_observer_phase_mutation_is_delayed`
- `test_observer_failure_commits_snapshot_and_retries_delivery`
- `test_observer_graph_order_precedes_reverse_registration_fail_fast`
- `test_dynamic_cycle_preserves_snapshot_matches_model`
- `test_generated_lifecycle_interleavings_preserve_generation_and_fence_stale_publish`
- `test_time_timer_start_failure_retries_necessary_timer`
- `test_time_interval_catches_up_arithmetically_without_daemon_yield`
- `test_time_now_uses_single_clock_snapshot_per_stabilization`
- `test_stream_bridge_interrupted_publish_does_not_duplicate`
- `test_stream_bridge_interrupted_drop_callback_does_not_duplicate`
- `test_stream_bridge_full_queue_drops_newest`
- `test_stream_dispose_closes_queue_after_buffered_updates`
- `test_stream_invalid_scope_closes_queue_with_invalid_scope`
- `test_stream_with_observed_disposes_on_exit`
- `test_commit_is_total_after_preflight`

Unchanged Signal Map QCheck property names stay registered without duplicate
properties.

Fixed-seed model tests remain stress evidence. They do not replace a generated
law when they lack branch accounting, counterexamples, or an empty census.

Replace these old authorities:

- transaction-ID overflow tests
- old stabilization fault matrices
- list-edge graph-algorithm tests
- registration-order-only observer tests
- the old outer-removal keyed test as N2 coverage
- inline core stream model tests
- unsafe object-token tests
- public keyed work-counter tests that the final `stats` record removes

The Signal Map migration rewrites the diagnostics requirements in
`docs/requirements/eta-signal-map/keyed-map.md`. The old ten-field
`keyed_stats` requirements become the two-field public `stable_family_stats`
contract from Ticket 13.

Input comparisons, diff events, child visits, provisional work, commits, and
discards become private economics counters. Update the corresponding `SD` law
rows in the same slice. No stale normative keyed-counter prose remains.

### Dune aliases and route

Add these aliases:

```text
@signal-laws
@signal-economics
@signal-gates
```

`@signal-laws` runs generated laws and focused correctness regressions.
`@signal-economics` runs only deterministic operation-count gates.
`@signal-gates` depends on both and on `@signal-map-complexity`.

`test/laws/dune` defines the local `signal-laws` alias.
`test/signal/economics/dune` defines the local `signal-economics` alias.
`test/signal_stream/dune` defines `signal-stream-laws`.
`test/signal/atomic_pass/dune` defines `signal-atomic-laws`.
`test/signal_map/keyed/dune` defines `signal-keyed-bind-laws`.

The repository-root `dune` file defines forwarding aliases with exact path
dependencies:

```lisp
(alias
 (name signal-laws)
 (deps
  (alias test/laws/signal-laws)
  (alias test/signal/atomic_pass/signal-atomic-laws)
  (alias test/signal_map/keyed/signal-keyed-bind-laws)
  (alias test/signal_stream/signal-stream-laws)))

(alias
 (name signal-economics)
 (deps (alias test/signal/economics/signal-economics)))

(alias
 (name signal-gates)
 (deps
  (alias signal-laws)
  (alias signal-economics)
  (alias lib/signal_map/bench/signal-map-complexity)))
```

Keep Signal wall-time benchmarks under `@bench`. They cannot satisfy
`@signal-economics`.

Use this implementation order:

1. Add final normative prose rows and property names with each API slice.
2. Add owner-local counters, fault slots, and typed probes.
3. Run the economics fixtures against the old engine to prove discrimination.
4. Implement atomic pass and the N1, N2, and N5 regressions.
5. Replace scheduler, demand, topology, observer, timer, and tombstone paths.
6. Make `@signal-economics` pass.
7. Add final observer, reduction, timer, and stream properties.
8. Migrate Signal Map laws to `Signal.Package` and typed probes.
9. Delete stale tests and registry rows with their removed APIs.
10. Replace `D-E22-004` and make `@signal-gates` pass.

Add `lib/signal_stream` and `test/signal_stream` to the OxCaml shipped build and
test lists. Replace its final `dune build @signal-map-complexity` command with
`dune build @signal-gates`.

Keep `@bench` separate from the shipped gate.

### Resolution spans

Line numbers refer to this issue.

| Census row | Resolution |
|---|---|
| SCP-009 | lines 27–33 |
| F01-032 | lines 337–393 and 554–565 |
| F03-001 | lines 56–88 |
| F03-002 | lines 56–122 and 239–335 |
| F03-005 | lines 64–70 |
| F03-006 | lines 64–70 |
| F03-007 | lines 68–74 and 456–505 |
| F03-010 | lines 56–88 and 90–335 |
| F03-011 | lines 124–237 and 554–565 |
| F03-012 | lines 90–122 and 239–254 |
| F03-013 | lines 103–122 and 124–237 |
| F03-014 | lines 124–250 |
| F03-015 | lines 256–292 |
| F03-016 | lines 294–335 |
| F08-008 | lines 107–115 and 432–439 |
| F13-004 | lines 337–454 |
| F13-005 | lines 23–25 and 551–552 |
| F13-008 | lines 395–454 |
| F13-009 | lines 385–393 and 435–445 |
| F13-010 | lines 368–454 |
| F13-011 | lines 23–25 and 551–552 |
| F13-012 | lines 554–565 |
| F13-013 | lines 35–54 and 507–575 |
| F13-023 | line 421 |
| F13-024 | line 422 |
| F13-025 | line 423 |
| F13-026 | line 424 |
| F13-027 | line 425 |
| F13-028 | lines 429–431 and 435–436 |
| N01-010 | lines 169–207 |
| N01-024 | lines 169–207 |
| N01-030 | lines 183–203 |
| N01-031 | lines 183–203 |
| N01-032 | lines 205–207 |
| N02-023 | lines 209–237 |
| N02-037 | lines 209–237 |
| N02-042 | line 216 |
| N02-043 | line 217 |
| N02-044 | lines 219 and 225–234 |
| N02-045 | line 220 |
| N04-016 | lines 429–431 and 435–436 |
| S01-001 | line 101 and lines 117–119 |
| S03-001 | line 101 and lines 117–119 |
| S04-001 | line 103 and lines 121–122 |
| S06-001 | line 104 and lines 121–122 |
| S07-001 | line 105 and lines 121–122 |
| S08-001 | line 106 and lines 121–122 |
| S17-004 | line 109 and lines 121–122 |
| PLN-01-005 | lines 169–207 |
| PLN-02-005 | lines 209–237 |
| PLN-04-001 | lines 337–454 and 507–575 |
| PLN-04-002 | lines 554–565 |
| PLN-04-003 | lines 35–54 and 337–454 |
| PLN-10-001 | lines 56–88 and 554–565 |
| PLN-10-003 | lines 35–88 and 507–575 |

### Implementation consequences

1. Replace blanket Signal debt with a claim-complete final law registry.
2. Add generated laws with named boundaries, classes, and discriminators.
3. Add N1 and N2 adversarial regressions before their fixes merge.
4. Add owner-local counters and typed graph-branded probes.
5. Gate 1,000, 10,000, and 100,000 node or edge controls.
6. Require deterministic counts and reject wall-time pass criteria.
7. Require cleanup and empty-fiber checks on every applicable effectful case.
8. Move stream laws to `eta_signal_stream`.
9. Delete stale tests and registry rows with their removed APIs.
10. Run the complete surface through `@signal-gates`.
