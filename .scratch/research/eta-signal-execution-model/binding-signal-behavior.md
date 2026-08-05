# Binding Signal behavior

Date: 2026-08-05

## Purpose

This report defines the behavior oracle for the Eta Signal execution-model
effort. It separates observable contracts from the current engine structure.

The census covers `eta_signal`, `eta_signal_map`, and the Eta core behavior that
their public operations expose. Eta Crux is not part of this census.

## Binding rule

A rule is binding when a caller can observe it through one of these surfaces:

1. a public type or function
2. a returned value or typed failure
3. a callback, lifecycle event, or defect
4. a compile-time acceptance or rejection
5. documented statistics or DOT output
6. a declared affected-work or map-comparison bound

A private record, phase, queue, counter, edge, or transaction is not binding.
The resulting public behavior can still be binding.

For example, failed stabilization must preserve the committed snapshot. A
universal staged-cell transaction is only one implementation of that rule.

## Authority

Use these sources in this order:

1. The current public `.mli` files define the current interface.
2. Public, contract, model, law, and negative tests define executable behavior.
3. Current requirements define package and complexity contracts.
4. The earlier Signal specification supplies scenarios and rationale only.
5. Private unit tests supply counterexamples, not mandatory representations.

The executable-law registry remains the claim index:
`.scratch/research/dx/e22/review/LAWS.md`.

The earlier specification cannot remain an authority as a complete document.
It contains current behavior, superseded architecture, and stale public types.

Examples:

- Its `graph_error` includes `Domain_mismatch`
  (`docs/wayfinder/eta-signal-direction/specification.md:191-214`).
  The current public type does not include this case
  (`lib/signal/eta_signal.mli:144-153`).
- It prohibits a stabilization token
  (`docs/wayfinder/eta-signal-direction/specification.md:241-250`).
  The current public contract reports stabilization and timer-token overflow
  (`lib/signal/eta_signal.mli:652-664`).
- Its statistics record differs from the installed public record
  (`docs/wayfinder/eta-signal-direction/specification.md:613-640`,
  `lib/signal/eta_signal.mli:268-345`).

Thus the new architecture must not import an earlier private section by
default.

## Scalar Signal behavior

| ID | Binding behavior | Observation point | Authoritative sources |
|---|---|---|---|
| SB01 | Each `Make` application creates one graph brand. Values from different brands do not compose. Raw signals, nodes, scopes, transactions, and graph mutation stay unavailable. | Public type-checking | `lib/signal/eta_signal.mli:184-259,473-482`, `test/signal/negative/cross_graph_signal_negative.ml`, `private_kernel_negative.ml`, `private_transaction_negative.ml`, `raw_signal_read_negative.ml` |
| SB02 | A graph has one owner domain. Wrong-domain and registered-worker calls fail. Effectful calls serialize competing Eta fibers. Cancellation prevents an ungranted operation from running. | Exceptions, effect exits, and public operation traces | `lib/signal/eta_signal.mli:103-111`, `test/signal/contract/test_eta_signal_contract.ml:156-205`, `test/signal/test_eta_signal.ml:1642-1955` |
| SB03 | Cutoffs receive published then candidate. `always`, `never`, `phys_equal`, `of_equal`, and `of_compare` have their documented suppression meanings. | Published values and callback traces | `lib/signal/eta_signal.mli:127-142`, law rows SC01-SC05, contract tests at `test/signal/contract/test_eta_signal_contract.ml:1207-1475` |
| SB04 | `Var.value` reads the latest accepted source value. `Observer.read` reads the last committed observed value and never stabilizes the graph. | Public reads before and after stabilization | `lib/signal/eta_signal.mli:353-409,454-460`, `test_explicit_stabilization_boundary`, `test_observer_read_does_not_force_recompute`, model tests for coalesced sets |
| SB05 | `Var.set` accepts callback-phase writes for a later stabilization. `update_effect` has exclusive update ownership and preserves the value after interruption. | Source reads, effect exits, and later observer reads | `lib/signal/eta_signal.mli:397-409`, debt rows SDD-01 and SDD-02, `test/signal/test_eta_signal.ml:1519-1641`, `test_effectful_update_trace_matches_model` |
| SB06 | `const`, `map` through `map9`, `all`, and repeated constructor slots produce dependency-correct values. Multiple source writes coalesce at explicit stabilization. | Observer values and callback counts | `lib/signal/eta_signal.mli:483-630`, `test/signal/contract/test_eta_signal_contract.ml:206-541`, `test_generated_small_graphs_match_model`, `test_diamond_trace_matches_model` |
| SB07 | Pure graph callbacks are total and have no contracted side effects. Callback exceptions are defects. A failed attempt can evaluate a pure closure again. | Defect channel and retry trace | `lib/signal/eta_signal.mli:490-513,631-650`, `test_pure_failure_preserves_snapshot_and_retries`, `test_pure_failure_matches_model` |
| SB08 | Balanced reduction copies its input, preserves order, applies `identity`, and exposes the documented logarithmic changed-leaf work. Only the final cell applies the caller cutoff. | Values, combine-call counts, and affected-work counts | `lib/signal/eta_signal.mli:605-620`, law rows SC06-SC09, balanced-reduction contract tests |
| SB09 | Stabilization is explicit. Successful stabilization publishes one consistent value snapshot before observer delivery and timer cleanup. | Reads and callbacks during one operation | `lib/signal/eta_signal.mli:652-674`, `test_observer_callbacks_read_consistent_published_snapshot`, `test_observer_phase_mutation_is_delayed`, matching model tests |
| SB10 | A pre-publication failure preserves committed values and topology and leaves admitted source work retryable. A post-publication failure never rolls back that snapshot. | Observer reads, branch identity, failure exit, and retry | `lib/signal/eta_signal.mli:652-674`, `test_bind_selector_failure_preserves_previous_branch`, `test_bind_switch_is_not_committed_when_later_pure_node_fails`, `test_observer_failure_commits_snapshot_and_retries_delivery`, model failure tests |
| SB11 | Graph failures use the documented typed cases. Synchronous construction uses `Graph_error`. Effectful operations use the Eta error channel. Monotonic counters fail instead of wrapping. | Exception or typed effect exit | `lib/signal/eta_signal.mli:144-153,224-256,652-664`, `test/signal/test_eta_signal_overflow.ml`, error-rendering contract tests |
| SB12 | `bind` selects the current branch, invalidates replaced branch scopes, and rejects invalid captured signals. Nested switches settle in one stabilization. Failure preserves the old branch. | Observer values, typed invalid-scope reads, and retained branch identity | `lib/signal/eta_signal.mli:632-650`, `test/signal/test_eta_signal.ml:703-1303`, `test/signal/test_eta_signal_public.ml:158-215,478-561`, bind model tests |
| SB13 | Demand starts at observers and necessary parents. Demand loss stops unnecessary timers and permits unreachable roots to be collected. Reactivation computes a fresh value. | Weak-reference collection, timer state, observer values, and statistics | `test_unnecessary_root_nodes_are_gc_reclaimable`, `test_observer_without_on_update_owns_demand`, `test_derived_demand_reactivates_fresh`, `test_demand_boundary_for_derived_nodes_and_timers`, demand model tests |
| SB14 | Observer registration does not run callbacks before the handle transfer completes. The first delivered event is `Initialized`. Reads report every documented invalid state. | Callback timing, returned handle, and typed read failures | `lib/signal/eta_signal.mli:247-267,411-460`, `test/signal/test_eta_signal.ml:385-702`, `test_basic_observe_stabilize_read`, negative observer-read fixture |
| SB15 | One stabilization uses one deterministic callback order. Dependencies precede consumers. Same-signal and unrelated ready groups use the documented identity order. | Complete callback trace | `lib/signal/eta_signal.mli:449-452`, law row SC13, observer-order contract tests and the `A < C < B` counterexample |
| SB16 | Disposal is idempotent. It skips pending callbacks, releases demand, and runs `on_finish` once. Dynamic invalidation finishes with `Invalid_scope`. | Callback trace, finish reason, observer read, timer state | `lib/signal/eta_signal.mli:414-470`, law rows SC11-SC14, observer lifecycle tests and model traces |
| SB17 | Observer delivery is fail-fast and at least once while active. A failed callback keeps eligible delivery pending and coalesces to the latest committed value. | Typed failure, callback trace, retry, and observer read | `lib/signal/eta_signal.mli:442-447,652-674`, `test_observer_failure_retries_pending_delivery`, `test_observer_callback_failure_channels_are_distinct`, observer-failure model test |
| SB18 | Timer values use one runtime monotonic clock. One-shots use exact deadlines. Intervals catch up arithmetically and saturate. Timer demand owns daemon lifetime. Timer wakes never stabilize. | Time values, sleep deadlines, typed errors, daemon census, and observer values | `lib/signal/eta_signal.mli:698-755`, law row SC15, public timer tests, timer model traces, `test/signal/test_eta_signal.ml:1973-2934` |
| SB19 | Public diagnostics observe committed state without changing graph behavior. They exclude user values. Their public fields and DOT options keep their documented meanings. | `stats`, DOT text, observer trace, and empty fiber census | `lib/signal/eta_signal.mli:268-345,676-696`, law row SC17 and SD01-SD15, contract diagnostics tests, Signal Map diagnostics tests |
| SB20 | The sealed stream delivery interface exposes current-event and acknowledgement behavior without exposing cursor or token authority. | Public type-checking and stream delivery traces | `lib/signal/eta_signal.mli:155-183,473-479`, law row SC26, Signal Stream bridge tests |

The engine can change the mechanisms behind SB02, SB09, SB10, SB13, and SB15.
It must preserve their observations until the public-interface decision changes
one explicitly.

## Signal Map behavior

| ID | Binding behavior | Observation point | Authoritative sources |
|---|---|---|---|
| MB01 | `Map.Make` uses comparator equality as key identity. Bindings remain ordered and unique. Stored key representatives follow the documented replacement rules. | Lookups, folds, lists, and returned keys | `lib/signal_map/eta_signal_map.mli:3-65`, law rows SM01-SM27, map semantic properties |
| MB02 | Map edits are persistent. Public physical no-ops preserve the map root. Earlier snapshots retain their bindings. | Public values, extensional reads, and physical equality of abstract map values | `lib/signal_map/eta_signal_map.mli:21-77`, law rows SM07-SM33, map semantic and representation properties |
| MB03 | `equal` and `fold_symmetric_diff` have the documented call counts, stop rules, event variants, representatives, physical-data boundary, order, and reconstruction laws. | Predicate trace and diff event sequence | `lib/signal_map/eta_signal_map.mli:79-109`, law rows SM34-SM45, `test/laws/map_semantic_properties.ml` |
| MB04 | Same-path `Map.Make` applications have compatible types. Different paths have incompatible types. | Public type-checking | `lib/signal_map/eta_signal_map.mli:112-115`, positive and negative Map functor fixtures |
| MB05 | Shared-ancestry diff work follows the declared comparison bound. Independent snapshots remain correct with linear work. | Key-comparison count and event sequence | `lib/signal_map/eta_signal_map.mli:105-109`, law rows SP01-SP02, `@signal-map-complexity` |
| MB06 | `Keyed(Order).mapi` creates one child incarnation for each present key. Continuous presence preserves that child. Removal ends it, and re-entry creates a fresh child. | Builder calls, child-local state, observer values, and invalid-scope reads | `lib/signal_map/eta_signal_map.mli:142-181`, law rows SK01-SK13 and SK26, keyed public and generated properties |
| MB07 | The keyed data cutoff applies only to retained physical changes. It uses published then candidate and retains the published baseline after suppression. | Cutoff-call trace, child data, and output map | `lib/signal_map/eta_signal_map.mli:165-173`, law rows SK14-SK20, keyed cutoff properties |
| MB08 | Input additions, removals, data updates, and changed child outputs patch one persistent output. No output change preserves the output root. | Output bindings, root physical identity, and downstream diff | `lib/signal_map/eta_signal_map.mli:175-181`, law rows SK21-SK26, keyed output properties |
| MB09 | A failed keyed attempt preserves committed data, child identity, scope validity, and output root. Success publishes one final output and observer event. | Child tokens or state, reads, callbacks, output root, and retry | `lib/signal_map/eta_signal_map.mli:183-191`, observable parts of STX01-STX17, keyed failure properties and model trace |
| MB10 | Keyed reconciliation and downstream diff satisfy the declared change-proportional comparison and child-visit bounds. | Comparison counters, selected-child visits, and diff events | `lib/signal_map/eta_signal_map.mli:193-206`, law rows SP03-SP08, `@signal-map-complexity` |
| MB11 | Keyed statistics and DOT output report their documented committed state without retaining or formatting keys and values. | `stats`, DOT text, observer trace, and ownership probes | `lib/signal/eta_signal.mli:268-345,676-696`, requirements `smdiag-*`, law rows SD01-SD15 |
| MB12 | `eta_signal_map` adapts an existing graph. It does not create a second graph or add its dependencies to root Eta. | Public types and installed package metadata | `lib/signal/eta_signal.mli:184-222,481-482`, `lib/signal_map/eta_signal_map.mli:140-148`, package law rows SMP01-SMP09 |

## Architecture that reopens

The following choices are not part of the behavior oracle.

| Area | Reopened choices | Behavior that remains binding |
|---|---|---|
| Atomic publication | `Idle/Planning/Delivering`, physical transaction identities, staged cells, sealed tapes, preflight objects, and commit-plan records | SB09-SB11, SB17, and MB09 |
| Scheduling | Work ledger fields, intrusive FIFO shape, explicit traversal stacks, visit marks, and direct-recompute shortcuts | SB06, SB08, SB12-SB13, and affected-work gates |
| Topology | Edge records, immutable edge arrays, dynamic vectors, reverse-edge storage, and removal repair | Dependency order, demand, scope invalidation, and complexity gates |
| Demand | Reference-count representation, demand plans, and transition queues | SB13 and timer ownership in SB18 |
| Observer planning | Kahn traversal, binary heaps, candidate-group records, cursor fields, and delivery tokens | SB14-SB17 |
| Graph serialization | The current lane record, waiter queue, fiber-local depth, resolver grants, and Eio scheduling arrangement | SB02 and public cancellation outcomes |
| Timers | Refresh contexts, dirty journals, generation records, daemon state records, and cancellation-hook layout | SB18 and timer-related parts of SB10 and SB16 |
| Diagnostics | The exact 1,024-slot tombstone ring, internal counters, and retained diagnostic records | SB19 and MB11 |
| Map storage | Weight-balanced tree nodes, exact balance constants, subtree representation, and diff traversal implementation | MB01-MB05 |
| Stable families | Plan types, provisional tables, private scope tokens, and owner-preflight ordering as an algorithm | MB06-MB10 |
| Module structure | The current engine module list and each current private interface | Package rules in MB12 |

The private law rows SX01-SX08, STX01-STX17, and SMR01-SMR08 do not bind their
representations. Their public outcomes remain binding when SB or MB rows cite
them.

Private tests under these directories are scenario sources:

- `test/signal/atomic_pass`
- `test/signal/bind`
- `test/signal/cleanup`
- `test/signal/kernel`
- `test/signal/lane`
- `test/signal/observer_plan`
- `test/signal/scope`
- `test/signal/timer`
- `test/signal/transaction`
- `test/signal_map/keyed_private`

A replacement can delete these tests with their modules. It must migrate each
unique public counterexample to the replacement interface or integrated suite.

## Prototype oracle

Early raw-kernel prototypes do not need Eta Effect, Eio, timers, or public
diagnostics. They must first cover these observations:

1. explicit source admission and stabilization
2. dependency-first static propagation
3. cutoff suppression and published-baseline behavior
4. coalesced writes
5. one consistent committed snapshot
6. pre-publication failure with retry
7. bind replacement and invalid-scope behavior
8. demand activation and release
9. deterministic observer candidate order
10. keyed child continuity and affected-child work

Later prototypes add observer lifecycle, timer lifecycle, cancellation, and
public diagnostics through separate adapters.

The integrated finalist must pass all applicable public, contract, model,
negative, law, and complexity suites. It need not preserve tests for deleted
private representations.

The current broad gate remains useful:

```sh
nix develop -c dune build @signal-gates
nix develop -c dune runtest test/signal test/signal_map --force
```

The final architecture can replace this gate when it deletes obsolete private
tests. The replacement gate must retain every SB and MB observation.

## Decision

The binding oracle is the SB and MB census in this report. Existing internal
types and algorithms are not compatibility targets.

This separation lets the next prototypes remove Effect, Eio, lanes, or
transactions from the raw graph kernel. Each prototype must still demonstrate
the affected public observations.
