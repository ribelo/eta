# Eta Signal complete-repository evidence matrix

## Scope

This report answers Wayfinder ticket 01 for findings F1-F14 and N1-N5.
The evidence baseline is `96f77eba3d2eedf72950f0a8e9797a26770dc516`.

Repository source, tests, requirements, ADRs, and prior decisions are the
authority for this report. The independent review supplied questions, not
answers.

Each item has one downstream design owner. Prototype tickets remain evidence
precursors and do not own the final decision.

Eta is a library. Repository use search cannot observe external consumer value.
This report uses absence as implementation inventory only. It does not use
absence to justify interface omission, rejection, or deletion.

## Revision record

`5694938a584edfdc05e33ad7df684eeb2a0bd5d5` is the probe baseline named by the
audit. Its subject is `feat: add fail-fast blocking admission`.

`4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc` is the direct child of `5694938a`.
It adds eight audit files and 935 lines under
`.scratch/research/eta-signal-incremental-audit/`. These files include the
probes and their recorded results.

The evidence baseline is three commits after `4197be98`. Those commits add the
independent review and the Eta Signal direction Wayfinder files. They do not
change Signal implementation, interfaces, tests, requirements, ADR 0004, the
kernel contract, or the law registry.

The repository confirms this result in two ways:

- `git diff --quiet` succeeds for the relevant paths across
  `5694938a..4197be98` and `4197be98..96f77eba`.
- The Git tree objects for `lib/signal`, `lib/signal_map`, `test/signal`, and
  `test/signal_map` are identical at all three revisions.
- The `LAWS.md` blob is
  `c23df95fd8678976e4eb399329e74f71e29b315f` at all three revisions.

The exact Git objects are:

| Primary evidence path | `5694938a` | `4197be98` | Evidence baseline |
| --- | --- | --- | --- |
| `lib/signal` | `62fd538905f00271d39afde2a80a225d5eb12eb8` | same | same |
| `lib/signal_map` | `aa9072034dcac87ef4118441678ab572b664db51` | same | same |
| `test/signal` | `8e83fa35b42a3416b3605bfb79ed36cab99019ee` | same | same |
| `test/signal_map` | `26ca7fb3591ac81d5bc7b6312e6124ad518ae497` | same | same |
| `test/laws` | `6478dba15fbdd6a1966753f04a622bdf93fe70b0` | same | same |
| `.scratch/research/dx/e22/review/LAWS.md` | `c23df95fd8678976e4eb399329e74f71e29b315f` | same | same |
| `docs/requirements/eta-signal` | `9f5c4c3d2b4204d41df33960cf0c8585cf86b793` | same | same |
| `docs/requirements/eta-signal-map` | `f394db4ec17f5bade803db94c1261e6311e42a8b` | same | same |
| ADR 0004 | `e40c90932cf70b24a97be5543dd857a34b71c529` | same | same |
| Signal PRD | `262875f272723cd8c019741fe49db725b94befb8` | same | same |
| Kernel contract | `b3e1002f1d7545c96f728165407b70aafa273452` | same | same |

Thus, the packed code, the probe baseline code, and current Signal code are
identical. Only the available research and planning records differ.

The old wall-time results still have measurement limits. The current repository
has no deterministic core-work gate that can replace them.

## Cross-artifact commitments

The current artifacts contain four important commitments:

- The PRD requires necessary stale nodes to run in deterministic topological
  order (`docs/prds/0002-eta-signal-frp.md:133-149`).
- The keyed requirements put every fallible operation before pure commit
  (`docs/requirements/eta-signal/keyed-extension.md:27-32`,
  `docs/requirements/eta-signal-map/keyed-map.md:95-113`).
- ADR 0004 and the completed keyed-map Wayfinder select a closed,
  package-private engine seam
  (`docs/adrs/0004-lean-eta-signal-with-a-sibling-eta-signal-map.md:16-39`,
  `docs/wayfinder/eta-signal-keyed-map/map.md:35-47`).
- Eta Crux plans to create roots with `Eta_signal_map.Make` and keep Signal
  types private
  (`docs/wayfinder/eta-signal-keyed-map/issues/12-eta-crux-integration-boundary.md:67-75`).

F1 conflicts with the first implementation-economics intent. N1, N2, and N5
weaken the second commitment. F2 and F10 follow from the final two commitments.

## Finding matrix

### F1 - Stabilization is not change-proportional

**Current evidence.** Generation caching avoids duplicate computation after a
node is reached (`Eta_signal_graph.compute_cached`,
`lib/signal/eta_signal_graph.ml:759-786`). It does not avoid traversal.

Each reachability call creates a new table and walks roots
(`fold_reachable`, `lib/signal/eta_signal_graph.ml:827-836`).
`necessary_ids` also scans the weak registry
(`lib/signal/eta_signal_graph.ml:1811-1825`).

Timer demand scans live nodes and walks roots again
(`lib/signal/eta_signal_graph.ml:1840-1848`). Post-commit timer work repeats
both actions (`lib/signal/eta_signal_graph.ml:1855-1866`).

Bind planning repeatedly collects all reachable binds until no new bind is
planned (`plan_staged_bind_switches`,
`lib/signal/kernel/eta_signal_kernel.ml:2407-2455`).
Observer comparisons can perform two dependency searches
(`lib/signal/eta_signal_graph.ml:808-825`).

**Assessment.** Confirmed. User-function recomputation can be
change-proportional, but every stabilization performs wider graph work.

**Existing coverage.** `test_recompute_order_is_topological` checks functional
order (`test/signal/test_eta_signal.ml:472-523`).
`test_map_invariants_repeated_children_cutoff_and_final_values` checks one
recompute per shared child (`test/signal/contract/test_eta_signal_contract.ml:354-436`).
`test_derived_demand_reactivates_fresh` checks that unnecessary nodes do not
recompute (`test/signal/contract/test_eta_signal_contract.ml:1698-1780`).

**Missing checks.** No test counts registry cells, root visits, dependency
searches, bind candidates, fixpoint passes, or timer visits. No test proves
constant work for a quiescent graph. No test compares narrow-change work at
1,000, 10,000, and 100,000 nodes.

**Downstream owner.** Ticket 10, `scheduler-demand-and-topology`. Ticket 05
supplies the operation-count prototype.

### F2 - Closed engine and the claimed `Obj` production seam

**Current evidence.** `Eta_signal_map.Make` creates and includes a fresh kernel
instance (`lib/signal_map/api/eta_signal_map_api.ml:40-42`).
The keyed node kind and recomputation are inside the kernel
(`lib/signal/kernel/eta_signal_kernel.ml:527-573,1976-2122`).

The production adapter passes typed `keyed_map_ops` and `keyed_diff_ops`
(`lib/signal_map/api/eta_signal_map_api.ml:48-76`). It does not pass `Obj.t`.
The `Obj` tokens occur in the testing surface
(`lib/signal/kernel/eta_signal_kernel.ml:3584-3656`).

ADR 0004 selects a package-private kernel and rejects a general public graph
extension API (`docs/adrs/0004-lean-eta-signal-with-a-sibling-eta-signal-map.md:16-39`).
The earlier seam decision also selects a closed factory
(`docs/wayfinder/eta-signal-keyed-map/issues/07-eta-signal-extension-seam.md:36-76`).

**Assessment.** Amended. The engine is closed, and keyed support is embedded.
The production sibling-package path is typed. The `Obj` problem belongs to F7.

**Existing coverage.** `public_expert_negative.ml` proves that consumers cannot
name `Signal.Expert`. Its expected error is fixed in
`test/signal/negative/run.sh:81-82`.
`keyed_direct_api_positive.ml:1-11` checks the typed public keyed path.
`private_kernel_negative.ml` protects the public package boundary
(`test/signal/negative/run.sh:87-88`).

**Missing checks.** The repository cannot establish whether external library
authors need a node-kind seam. Ticket 12 must assess external use cases and
interface leverage. A future protocol needs compile checks that prevent phase,
scope, transaction, and arbitrary edge mutation by consumers.

**Downstream owner.** Ticket 12, `engine-and-package-seams`.

### F3 - Law-bearing `eta_signal.mli` prose is not completely registered

**Current evidence.** `eta_signal.mli` contains law-bearing observer prose
(`lib/signal/eta_signal.mli:328-372`), bind prose
(`lib/signal/eta_signal.mli:524-541`), stabilization prose
(`lib/signal/eta_signal.mli:543-565`), timer prose
(`lib/signal/eta_signal.mli:589-699`), and stream prose
(`lib/signal/eta_signal.mli:702-765`).

The registry states that its complete bootstrap scope excludes Signal
(`.scratch/research/dx/e22/review/LAWS.md:8-14`).
It records Signal interfaces as dated debt `D-E22-004`
(`.scratch/research/dx/e22/review/LAWS.md:699-703`).

The registry contains 15 exact `eta_signal.mli` rows. All are keyed diagnostic
rows `SD01-SD15`
(`.scratch/research/dx/e22/review/LAWS.md:274-292`).
It has no complete registry for observer, bind, stabilization, timer, or stream
laws.

**Assessment.** Settled and amended. F3 is real, but it is explicit historical
registry debt, not a hidden omission. Existing tests do not make the registry
complete.

**Existing coverage.** Examples include:

- observer order and snapshots:
  `test_observer_graph_delivery_order_is_deterministic`
  (`test/signal/contract/test_eta_signal_contract.ml:577-690`) and
  `test_observer_callbacks_read_consistent_published_snapshot`
  (`test/signal/contract/test_eta_signal_contract.ml:1539-1602`).
- rollback and retry:
  `test_equality_defects_preserve_committed_snapshots`
  (`test/signal/contract/test_eta_signal_contract.ml:1153-1221`) and
  `test_observer_failure_commits_snapshot_and_retries_delivery`
  (`test/signal/contract/test_eta_signal_contract.ml:1604-1673`).
- invalid scope:
  `test_bind_invalidates_old_scope_without_recomputing_obsolete_nodes`
  (`test/signal/test_eta_signal.ml:1060-1112`).
- stream terminal states:
  `test_stream_dispose_closes_queue_after_buffered_updates` and
  `test_stream_invalid_scope_closes_queue_with_invalid_scope`
  (`test/signal/contract/test_eta_signal_contract.ml:1996-2082`).

**Missing checks.** The registry needs one row per normative claim and exact
test names. N1, N2, N3, N4, and N5 need new discriminating tests before their
new laws enter the interface. Existing fixed tests must not be listed for
claims that they do not discriminate.

**Downstream owner.** Ticket 16, `laws-and-economics-gates`.

### F4 - Observer callbacks have no lifecycle update variant

**Current evidence.** Public updates contain only `Initialized` and `Changed`
(`lib/signal/eta_signal.mli:167-172`). Direct callbacks receive no finish event.

Observer lifecycle distinguishes disposal and invalid scope
(`lib/signal/eta_signal_observer.ml:100-169`).
The stream bridge maps disposal to clean close and invalid scope to error close
(`lib/signal/kernel/eta_signal_kernel.ml:69-90`).

An active or registering observer demands its signal
(`lib/signal/eta_signal_observer.ml:127-129`). Therefore, an active observed
root cannot produce a meaningful temporary `Unnecessary` update.

**Assessment.** Amended. Direct callbacks lack lifecycle events. Stream
consumers already distinguish disposal from invalidation. `Unnecessary` does
not fit the active-observer model.

**Existing coverage.** The two stream terminal tests at
`test/signal/contract/test_eta_signal_contract.ml:1996-2082` discriminate clean
close from `` `Invalid_scope``. `test_dynamic_scope_invalidation_skips_callback`
checks direct callback suppression
(`test/signal/test_eta_signal.ml:1417-1465`).

**Missing checks.** No direct-callback test can observe a finish reason because
the public API has no finish callback. If the API gains one, tests must cover
exactly-once disposal, invalidation, already-invalid disposal, and no value
event after finish.

**Downstream owner.** Ticket 13, `public-signal-algebra`.

### F5 - Support-layer over-abstraction

**Current evidence.** The graph interface says that callback records connect
one adapter and are not a reusable extension surface
(`lib/signal/eta_signal_graph.mli:1-13`).
The graph interface contains separate records for edge, dirty, compute, version,
order, reachability, staging, and stabilization plans
(`lib/signal/eta_signal_graph.mli:47-108,336-445,630-778`).

The observer and timer interfaces also expose many internal plan and port types,
for example `delivery_port`
(`lib/signal/eta_signal_observer.mli:133-180`) and `state_port`
(`lib/signal/eta_signal_timer.mli:64-70`).

**Assessment.** Supported as an architecture concern, not a proved universal
defect. A single-use module is valid when it owns a phase or lifecycle
invariant. A callback record is not invalid by form alone.

**Existing coverage.** Support-module tests check local state machines.
Examples are `test_generated_pure_failure_slots_roll_back`
(`test/signal/stabilization_pass/test_eta_signal_stabilization_pass.ml:419-459`)
and generated timer lifecycle tests
(`test/signal/timer/test_eta_signal_timer.ml:562-751`).

**Missing checks.** The repository has no ownership table that gives each
record one invariant. It also has no deletion test for single-caller wrappers.
N2 and N5 show that local tests do not prove the cross-module commit order.

**Downstream owner.** Ticket 15, `internal-module-ownership`.

### F6 - Five graph-algorithm functors lack production instantiations

**Current evidence.** Whole-repository symbol search finds:

- `Make_reachable`: definition, interface, and test instantiation at
  `test/signal/graph_algorithms/test_eta_signal_graph_algorithms.ml:33-40`.
- `Make_order`: definition, interface, and test instantiation at lines 42-50.
- `Make_versions`: definition, interface, and test instantiation at lines 52-59.
- `Make_dirty`: definition, interface, and test instantiation at lines 61-69.
- `Make_compute`: definition, interface, and test instantiation at lines 71-86.

The live graph duplicates these operations as direct functions
(`lib/signal/eta_signal_graph.ml:743-850`).
`Make_edges` is different. Production instantiates it as `Initial_edges`
(`lib/signal/kernel/eta_signal_kernel.ml:700-716`).

**Assessment.** The usage question is settled, but the design disposition is
not. The five named functors have test-only consumers and no production
instantiation. `Make_edges` remains live production code.

The functors are private implementation modules, not a supported external
interface. Their lack of production use does not justify deletion. Ticket 15
must compare deliberate private retention, canonical adoption, replacement,
and removal. If their algorithms give external consumers useful leverage,
ticket 12 must consider engine and package seams. Ticket 13 must consider
public Signal algebra. Neither ticket can expose private support types directly.

**Existing coverage.** The test-only functors have direct unit coverage in
`test_eta_signal_graph_algorithms.ml:205-228,284-326,399-472`.
These tests explain the mechanical test migration needed by deletion.

**Missing checks.** There is no missing behavioral counterexample. The design
must determine whether each functor owns a reusable algorithm or invariant. It
must compare deliberate retention, live-engine adoption, replacement, and
removal. Use count cannot select among these choices.

**Downstream owner.** Ticket 15, `internal-module-ownership`.

### F7 - `Obj` casts on the testing seam

**Current evidence.** `Extension.token` is `Obj.t`. One record uses it for keys,
scopes, sources, data signals, and child signals
(`lib/signal/kernel/eta_signal_kernel.ml:3584-3598`).
`keyed_entry_identity` uses `Obj.magic` for a caller key
(`lib/signal/kernel/eta_signal_kernel.ml:3625-3650`).
`keyed_scope_valid` reads any token as a scope with `Obj.obj`
(`lib/signal/kernel/eta_signal_kernel.ml:3655-3656`).

The public `Eta_signal_map` interface does not expose `Testing`
(`lib/signal_map/eta_signal_map.mli:118-186`).
The package-private API re-exports it
(`lib/signal_map/api/eta_signal_map_api.ml:78-103`).

**Assessment.** Confirmed, with limited reach. This is an unsafe private testing
protocol, not the production keyed protocol.

**Existing coverage.** Keyed properties compare token identity
(`test/laws/keyed_mapi_properties.ml:139-153,217-235`).
`keyed_testing_negative.ml:1-4` proves that ordinary public consumers cannot
name `K.Testing`.

**Missing checks.** No test passes a key token to `scope_valid`, a source token
as a scope, or a key of the wrong runtime type. Such calls can cause
representation confusion instead of a typed failure. Typed opaque token types
need compile-negative cross-kind checks.

**Downstream owner.** Ticket 12, `engine-and-package-seams`.

### F8 - No collection-fold family

**Current evidence.** The public Signal algebra ends with `both`, `all`, and
`bind` (`lib/signal/eta_signal.mli:496-541`). It has no signal reduction or
incremental fold.

`All` collects every child and materializes a list
(`lib/signal/kernel/eta_signal_kernel.ml:1963-1970`,
`lib/signal/eta_signal_graph_algorithms.ml:490-494`).
The PRD intentionally deferred collection folds without a concrete use case
(`docs/prds/0002-eta-signal-frp.md:63-68`).

**Assessment.** Confirmed as an interface capability gap. It is not yet a
correctness defect. No arbitrary fold can promise constant update work without
stronger algebra. Ticket 13 must evaluate external aggregation use cases.

**Existing coverage.** `test_n_ary_maps_both_and_all` checks current list
semantics (`test/signal/contract/test_eta_signal_contract.ml:224-288`).
`test_static_eval_all_preserves_order` checks internal order
(`test/signal/graph_algorithms/test_eta_signal_graph_algorithms.ml:504-515`).

**Missing checks.** There is no associative-law property, changed-child count,
balanced-depth check, removal law, or large-fan-in reduction gate. Any accepted
fold needs generated associativity inputs and exact operation counts.

**Downstream owner.** Ticket 13, `public-signal-algebra`.

### F9 - Small-surface parity gaps

**Current evidence.** Repository-wide declaration search finds no Signal
`join`, `freeze`, `if_`, `bind2` through `bind4`, node `on_update`,
`set_cutoff`, or snapshot API. It does find the intended core at
`lib/signal/eta_signal.mli:375-541`.

`Var.value` already returns the latest source value, including a set since the
last stabilization (`lib/signal/eta_signal.mli:292-298`).
The PRD rejects broad parity and defers `freeze`, snapshots, and folds
(`docs/prds/0002-eta-signal-frp.md:63-68,561-567`).

**Assessment.** Refuted as one defect. The absences are real, but they are
intentional or belong to different design classes.

**Existing coverage.** Negative fixtures protect selected omissions:
`computed_negative.ml`, `map10_negative.ml`, `public_expert_negative.ml`,
`raw_signal_read_negative.ml`, and `stream_to_signal_negative.ml`.
Their exact expected errors are in `test/signal/negative/run.sh:63-117`.

**Missing checks.** Do not add one parity test batch. Each accepted primitive
needs an external-usefulness rationale and a semantic contract. A rationale can
come from a concrete use case or coherent algebra. The test must distinguish
the primitive from a composition of existing primitives.

**Downstream owner.** Ticket 13, `public-signal-algebra`.

### F10 - Two independent graph functors are easy to create

**Current evidence.** `Eta_signal_map.Make` applies
`Eta_signal_kernel.Make` itself (`lib/signal_map/api/eta_signal_map_api.ml:40-42`).
A separate `Eta_signal.Make` application therefore owns another generative
signal type.

The public map interface includes the full core interface but gives no explicit
two-graphs warning (`lib/signal_map/eta_signal_map.mli:118-126`).
The README quick start uses the correct single factory
(`lib/signal_map/README.md:52-96`).
The prior seam decision states the rule explicitly
(`docs/wayfinder/eta-signal-keyed-map/issues/07-eta-signal-extension-seam.md:74-76`).

**Assessment.** Confirmed as a discoverability footgun. The type system keeps it
safe.

**Existing coverage.** `keyed_cross_graph_negative.ml:1-7` rejects keyed input
from another map graph. `cross_graph_signal_negative.ml:1-6` rejects ordinary
cross-graph composition.

**Missing checks.** Public module documentation must state that
`Eta_signal_map.Make` creates the complete graph and replaces a separate
`Eta_signal.Make` application. A documentation example must show the rejected
two-factory shape.

**Downstream owner.** Ticket 12, `engine-and-package-seams`.

### F11 - No bind rescope mode

**Current evidence.** `commit_switch` detaches the old inner, invalidates its
scope, and attaches the new inner
(`lib/signal/eta_signal_bind.ml:356-368`).
The public `bind` has no scope policy argument
(`lib/signal/eta_signal.mli:524-541`).

The current PRD requires old selector-scope invalidation
(`docs/prds/0002-eta-signal-frp.md:255-280`).

**Assessment.** The absence is confirmed. It is not a current contract defect.
Invalidation is the selected Eta behavior. A rescope mode needs separate
external consumer and lifecycle evidence.

**Existing coverage.** `test_bind_invalidates_old_scope_without_recomputing_obsolete_nodes`
checks the current rule (`test/signal/test_eta_signal.ml:1060-1112`).
The model suite checks repeated branch churn
(`test/signal/model/test_eta_signal_model.ml:2377-2383`).

**Missing checks.** No benchmark compares invalidation with rescoping. No test
defines behavior for captured ancestors, nested keyed children, timers,
observers, rollback, or a scope that becomes necessary again under rescoping.

**Downstream owner.** Ticket 13, `public-signal-algebra`.

### F12 - Cutoffs are fixed equality functions

**Current evidence.** Signals, vars, and observers each store one equality
function (`lib/signal/kernel/eta_signal_kernel.ml:442-458,578-613`).
Constructors install `?equal` or physical equality
(`lib/signal/kernel/eta_signal_kernel.ml:1172-1223,2794-2829`).

The public interface has no cutoff ADT and no mutation operation
(`lib/signal/eta_signal.mli:262-541`). Repository-wide search finds no Signal
`set_cutoff`.

**Assessment.** Confirmed as an interface structure gap. Runtime mutation
semantics remain undecided.

**Existing coverage.** Current fixed equality has strong tests:
`test_default_cutoff_is_physical_equality`,
`test_default_physical_cutoff_suppresses_in_place_mutation`, and
`test_source_cutoff_forces_same_block_propagation`
(`test/signal/contract/test_eta_signal_contract.ml:1060-1151`).
Equality defects are covered at lines 1153-1221.

**Missing checks.** A cutoff ADT needs `always`, `never`, physical, equality,
and comparison cases. Mutation needs tests for calls during pure and delivery
phases, immediate versus future reevaluation, pending dirty state, rollback,
and observer-local equality.

**Downstream owner.** Ticket 13, `public-signal-algebra`.

### F13 - No deterministic scale gate for the core engine

**Current evidence.** The core benchmark has one small diamond and one bind
workload, each repeated 10,000 times
(`lib/signal/bench/bench_signal.ml:23-104`). It reports wall time only.

The public stats expose recomputation counts, but not traversal work
(`lib/signal/eta_signal.mli:207-241`).
The Signal Map gate counts map comparisons and selected child visits. Its
contract explicitly excludes child computation, allocation, memory, wall time,
and constant factors (`lib/signal_map/eta_signal_map.mli:171-185`).

**Assessment.** Confirmed. The map gate does not cover the core scheduler,
observer ordering, registry scans, timers, or edge storage.

**Existing coverage.** Functional stress exists for fan-in
(`test/signal/contract/test_eta_signal_contract.ml:354-436`), nested bind churn
(`test/signal/model/test_eta_signal_model.ml:2377-2383`), and keyed affected
children (`test/signal/kernel/test_eta_signal_kernel.ml:12-39`).

**Missing checks.** Add exact counters for compute visits, edge checks, registry
cells, roots, dependency searches, bind passes, necessity visits, and timer
visits. Gate quiescent, narrow, half-graph, nested bind, keyed child, and wide
`all` workloads at several sizes.

**Downstream owner.** Ticket 16, `laws-and-economics-gates`. Ticket 05 supplies
the measurement prototype.

### F14 - Small duplication and `Stream_bridge` placement

**Current evidence.** `Stream_bridge` occupies the first 213 kernel lines and
owns queue publication, drop acknowledgement, finish mapping, and metrics
(`lib/signal/kernel/eta_signal_kernel.ml:19-213`).

Arithmetic helpers have different policies. Transaction IDs fail at exhaustion
(`lib/signal/eta_signal_transaction.ml:57-68`). Graph diagnostics saturate
(`lib/signal/eta_signal_graph.ml:347-366`). Timer arithmetic caps values
(`lib/signal/eta_signal_timer_policy.ml:178-215`).

**Assessment.** Amended. Extracting `Stream_bridge` gives one subsystem a clear
owner. A universal arithmetic helper can erase different overflow contracts.

**Existing coverage.** Stream behavior is covered by
`test_stream_bridge_is_observer_plus_queue`
(`test/signal/contract/test_eta_signal_contract.ml:1943-1967`) and the drop test
at lines 2150-2234. Timer saturation has policy and public tests, including
`test_time_interval_saturated_catch_up_coalesces`
(`test/signal/test_eta_signal.ml:2555-2573`).

**Missing checks.** No behavior test is needed only for moving the module.
The private extraction must preserve all current stream tests. Helper
deduplication is valid only after tests prove identical overflow and observation
boundaries.

**Downstream owner.** Ticket 15, `internal-module-ownership`.

### N1 - Transaction-ID overflow wedges stabilization

**Current evidence.** `begin_pure` writes `Pure` and active transaction status
before it allocates the transaction
(`lib/signal/eta_signal_stabilization.ml:107-115`).
Transaction allocation raises `Invalid_argument` at `max_int`
(`lib/signal/eta_signal_transaction.ml:41-68`).

`Stabilization_pass.run` calls `begin_pure` before its `try`
(`lib/signal/eta_signal_stabilization_pass.ml:274-294`).
Thus, allocation failure leaves `state = Pure`, active status, and no
transaction. Later calls return `` `Reentrant_stabilization``.

The public contract says overflow is typed and occurs before partial
publication (`lib/signal/eta_signal.mli:552-555`).

**Assessment.** Confirmed by the primary static trace. Reachability is remote,
but the state-machine corruption and contract violation are exact.

**Existing coverage.** The overflow harness can set signal versions, node IDs,
graph generations, timer tokens, and stats
(`test/signal/eta_signal_overflow_harness.ml:82-128`).
It cannot set the module-global transaction ID.
Current overflow tests are at
`test/signal/test_eta_signal_overflow.ml:128-222`.

**Missing checks.** Force the next transaction ID to `max_int`. Check the exact
typed error, idle phase, absent transaction, unchanged snapshot, retry success,
and two independent graphs on separate domains if a global allocator remains.

**Downstream owner.** Ticket 09, `transaction-and-invalidation-model`. Ticket 02
supplies the reproduction.

### N2 - Keyed removal can commit a staged nested bind

**Current evidence.** Bind switches are planned before ordinary event
collection (`lib/signal/kernel/eta_signal_kernel.ml:2407-2455`).
A keyed removal records the child without computing it
(`lib/signal/kernel/eta_signal_kernel.ml:2074-2091`).

`extend_keyed_invalidations` adds removed keyed scopes
(`lib/signal/kernel/eta_signal_kernel.ml:1508-1524`). It partitions keyed plans,
not `Graph.State.staged_binds`.

The preflight callback performs keyed removal and invalidation
(`lib/signal/kernel/eta_signal_kernel.ml:1670-1698`).
After that callback, `commit_staging` commits every staged bind
(`lib/signal/eta_signal_graph.ml:203-227`).
`commit_switch` attaches the new inner without checking owner validity
(`lib/signal/eta_signal_bind.ml:356-368`).

**Assessment.** Confirmed by the primary static trace. No current test executes
the complete public counterexample.

**Existing coverage.** Existing tests cover nearby but different cases:

- bind invalidation without keyed ownership:
  `test_commit_skips_invalidated_staged_entries`
  (`test/signal/test_eta_signal.ml:1467-1518`).
- an outer bind removing a nested keyed plan:
  `keyed_mapi_outer_removal_excludes_nested_plan`
  (`test/laws/keyed_mapi_properties.ml:522-545`).
- keyed removal ordering:
  `test_keyed_mapi_commit_removes_before_additions`
  (`test/signal_map/keyed_private/test_eta_signal_map_keyed_private.ml:29-64`).

None puts a bind inside a keyed child and removes that key while the bind
switches.

**Missing checks.** Use the exact same-stabilization key removal and nested-bind
switch. Check owner validity, old and provisional scope validity, the new
top-scope dependency's dependent list, pending work, DOT edges, and retained
node bounds across repeated cycles. Also cross the case with callback failure
after commit.

**Downstream owner.** Ticket 09, `transaction-and-invalidation-model`. Ticket 03
supplies the reproduction.

### N3 - Observer comparator is not a total order

**Current evidence.** The comparator uses dependency reachability first and
signal ID for unrelated nodes
(`lib/signal/eta_signal_graph.ml:808-825`).
The kernel uses it for observer sorting
(`lib/signal/kernel/eta_signal_kernel.ml:2393-2405`), and the observer module
passes it to `List.sort`
(`lib/signal/eta_signal_observer.ml:839-845`).

For IDs `A < C < B`, where `A` depends on `B`, the relation gives
`A > B`, `B > C`, and `A < C`. This relation is cyclic.

The PRD promises deterministic graph order and same-signal registration order
(`docs/prds/0002-eta-signal-frp.md:319-343`). The public `.mli` promises a
consistent snapshot but does not state dependency callback order
(`lib/signal/eta_signal.mli:328-350`).

**Assessment.** Confirmed. The current comparator is not a total order. The
desired public order remains a product decision.

**Existing coverage.** Static dependency, independent-node, same-signal, reverse
registration, and one bind-switch case exist
(`test/signal/contract/test_eta_signal_contract.ml:577-690`,
`test/signal/test_eta_signal.ml:525-620`).
They do not form the comparison cycle.

**Missing checks.** Build exact `A`, `B`, and `C` nodes. Enumerate creation and
registration orders. Check comparator transitivity, stable delivery, and
dependency-before-consumer only if that rule remains public.

**Downstream owner.** Ticket 11, `observer-delivery-contract`. Ticket 04
supplies the reproduction.

### N4 - Wide fan-in edge operations are quadratic

**Current evidence.** Edge attachment scans both adjacency lists with
`List.exists`. Detachment rebuilds lists with `List.filter`
(`lib/signal/eta_signal_graph_algorithms.ml:22-46`).

Node creation attaches dependencies one at a time
(`lib/signal/eta_signal_graph.ml:1719-1737`).
For `n` distinct children, the growing parent list has scan lengths
`0` through `n-1`. This gives quadratic attachment work.

Public `all` creates one node with the complete child list
(`lib/signal/kernel/eta_signal_kernel.ml:2827-2829`).

**Assessment.** Confirmed. This cost is independent of F1 stabilization scans.

**Existing coverage.** Generated edge tests check bidirectional consistency and
idempotence, not work
(`test/signal/graph_algorithms/test_eta_signal_graph_algorithms.ml:136-203`).
The functional fan-in test uses only small inputs
(`test/signal/contract/test_eta_signal_contract.ml:354-436`).

**Missing checks.** Count adjacency comparisons and removals for `all` with
1,000, 10,000, and 100,000 distinct children. Also count invalidation of a
scope with one wide parent. The expected accepted bound is linear.

**Downstream owner.** Ticket 10, `scheduler-demand-and-topology`. Ticket 05
supplies the operation-count prototype.

### N5 - One exception region spans commit

**Current evidence.** One `try` covers planning, commit, pending-event marking,
necessity update, timer-context clearing, and transition to delivery
(`lib/signal/eta_signal_stabilization_pass.ml:294-333`).

`commit_staging` commits the staged-cell transaction at
`lib/signal/eta_signal_graph.ml:203-227`. After that commit, rollback is no
longer valid. `rollback_transaction` requires a live transaction
(`lib/signal/eta_signal_stabilization.ml:162-172`).

**Assessment.** Confirmed as a latent exception-boundary defect. The repository
does not show a current ordinary post-commit operation that intentionally
raises. The control flow still calls rollback for any such future exception.

**Existing coverage.** `test_generated_pure_failure_slots_roll_back` injects
failures only through `Commit_staging`
(`test/signal/stabilization_pass/test_eta_signal_stabilization_pass.ml:68-116,419-459`).
It has no slots after commit. `test_rollback_after_transaction_commit_rejected`
proves that rollback is invalid after commit
(`test/signal/stabilization/test_eta_signal_stabilization.ml:205-212`).

**Missing checks.** Add fault slots after transaction commit, after event
marking, during necessity update, during timer-context clear, and before the
delivery transition. Prove that none invokes rollback or leaves `Pure`.

**Downstream owner.** Ticket 09, `transaction-and-invalidation-model`.

## Exact N1-N5 test ledger

The names in the missing column are proposed exact test names. No current file
contains those names.

| Finding | Exact existing tests | Exact missing tests and checks |
| --- | --- | --- |
| N1 | `test_signal_version_overflow_does_not_publish_partial_snapshot`, `test_stabilization_generation_overflow_is_typed_failure`, and `test_timer_refresh_token_overflow_is_typed_failure` (`test/signal/test_eta_signal_overflow.ml:128-187`). `test_begin_opens_transaction` and `test_reentrant_begin_rejected` cover normal phase entry (`test/signal/stabilization/test_eta_signal_stabilization.ml:54-73,155-172`). | `test_transaction_id_overflow_is_typed_and_retryable`: force transaction-ID exhaustion, require `` `Counter_overflow "transaction id"``, require `Idle`, require no transaction, then stabilize successfully. `test_transaction_identity_is_graph_local_across_domains`: if integer IDs remain, run two graphs on separate domains and require independent identity allocation. |
| N2 | `test_commit_skips_invalidated_staged_entries` (`test/signal/test_eta_signal.ml:1467-1518`). `keyed_mapi_outer_removal_excludes_nested_plan` (`test/laws/keyed_mapi_properties.ml:522-545`). `test_keyed_mapi_commit_removes_before_additions` (`test/signal_map/keyed_private/test_eta_signal_map_keyed_private.ml:29-64`). | `test_keyed_removal_discards_nested_bind_switch_to_top_scope`: remove a key while its child bind switches to a top-scope signal, then require no invalid dependent edge. `test_keyed_removal_invalidates_nested_bind_provisional_scope`: require invalid provisional scope and no pending staged bind. `test_keyed_bind_remove_switch_churn_has_bounded_topology`: repeat the cycle and bound live and dead node counts. `test_keyed_removal_nested_bind_topology_survives_callback_failure`: fail a later observer callback and require coherent committed topology. |
| N3 | `test_observer_graph_delivery_order_is_deterministic` (`test/signal/contract/test_eta_signal_contract.ml:577-690`). `test_observer_graph_order_precedes_reverse_registration_fail_fast` and `test_observer_graph_order_after_bind_switch_uses_new_inner` (`test/signal/test_eta_signal.ml:525-620`). | `test_observer_dynamic_graph_order_is_total_for_a_b_c`: build IDs `A < C < B` with `A` depending on `B`, then require a transitive relation. `test_observer_dynamic_graph_order_is_stable_across_registration_permutations`: enumerate observer registration orders and require one delivery order. Require dependency order only if ticket 11 keeps that law. |
| N4 | `test_attach_is_bidirectional_and_idempotent`, `test_detach_removes_both_edges`, and `test_generated_edge_sequences_preserve_bidirectional_consistency` (`test/signal/graph_algorithms/test_eta_signal_graph_algorithms.ml:136-203`). `test_n_ary_maps_both_and_all` covers small functional fan-in (`test/signal/contract/test_eta_signal_contract.ml:224-288`). | `test_wide_all_attachment_is_linear`: count adjacency work at 1,000, 10,000, and 100,000 children. `test_wide_all_invalidation_is_linear`: count teardown work for one wide scoped parent. Both tests must fail a quadratic implementation by exact operation ceilings. |
| N5 | `test_generated_pure_failure_slots_roll_back` covers failure slots only through `Commit_staging` (`test/signal/stabilization_pass/test_eta_signal_stabilization_pass.ml:68-116,419-459`). `test_rollback_after_transaction_commit_rejected` proves rollback is invalid after commit (`test/signal/stabilization/test_eta_signal_stabilization.ml:205-212`). | `test_post_commit_event_mark_failure_never_rolls_back`, `test_post_commit_necessity_failure_never_rolls_back`, `test_post_commit_timer_clear_failure_never_rolls_back`, and `test_post_commit_delivery_transition_failure_never_rolls_back`. Each test must require the committed snapshot, a non-`Pure` phase, and no rollback call. |

## Answers to the seven maintainer evidence questions

1. **Which revision is authoritative?** The evidence baseline is authoritative
   for this ticket. Relevant Signal evidence is identical at `5694938a`,
   `4197be98`, and the evidence baseline. The old probe results are not
   deterministic gates.

2. **What do the registry and complete tests settle?** They settle F3 and F6.
   F3 is explicit incomplete historical debt. F6 has five test-only functors and
   one live production functor, `Make_edges`.

3. **Is dependency-ordered callback delivery public law?** The PRD and current
   tests require graph order. The public `.mli` does not state it. Ticket 11 must
   resolve this conflict before the law registry records a final rule.

4. **Does an N2 regression already exist?** No. The closest test removes a
   nested keyed node through an outer bind. It does not remove a keyed child
   that owns a switching bind.

5. **Is `Keyed.Testing` an external public API?** No. The public CMI omits it,
   and `keyed_testing_negative.ml` enforces that omission. Package-private tests
   still use its unsafe generic tokens.

6. **What does ADR 0004 reject?** It rejects a general application-facing graph
   extension API. It accepts a package-private protocol. It does not explicitly
   forbid a future sealed first-party protocol that hides graph mutation.

7. **What are cutoff mutation semantics?** The repository does not decide them.
   All current cutoffs are fixed at construction. Ticket 13 must decide
   immediate reevaluation versus future-candidate-only behavior.

## Repository evidence used

The inspection used these read-only command classes:

- `git show`, `git log`, `git diff --name-status`, `git diff --quiet`,
  `git rev-parse`, and `git rev-list` for revision identity and ancestry.
- `find` for Signal, Signal Map, test, requirement, ADR, and Wayfinder files.
- `rg -n` for whole-repository symbols, test names, `Obj` use, cutoff APIs,
  graph functors, and complexity terms.
- `nl -ba` with `sed -n` for exact current source and test spans.

The first Nix test attempt stopped before Dune because the sandbox made the
normal Nix cache read-only. This cache-local retry passed:

```sh
XDG_CACHE_HOME=/tmp/eta-nix-cache \
  nix develop -c dune runtest test/signal test/signal_map test/laws --force
```

No benchmark result was treated as proof. No production code or test changed.
