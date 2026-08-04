# Eta Signal vs Jane Street Incremental — completeness and code-quality audit

Date: 2026-08-04. Author: audit per batch-grill-me settled scope.
Baseline under audit: worktree `master` @ `5694938a` (installed into the OxCaml
switch as `eta_signal 5694938` for probes).

Reference baselines:

- `.reference/incremental` @ `2e8ccbf` (`v0.18~preview.130.100+614`), the
  pinned Jane Street `incremental` checkout.
- `.reference/incr_map` @ `21c6bc6` (`v0.18~preview.130.106+341`), cloned for
  this audit into `~/projects/github/incr_map` and symlinked per the
  `.reference/` convention.

## 1. Executive summary

Eta Signal is a **semantically credible** incremental-computation library:
every semantic property the audit could check against the Jane Street
reference holds — glitch freedom, bind-switch lifecycle, observer delivery
coalescing, deferred var sets during stabilization, transactional rollback of
failed stabilizations, and extreme graph-depth robustness (1.6M-node chains
stabilize successfully; incremental itself errors above `max_height_allowed`,
default 128).

The two significant deficits are **scheduling economics** and **interface
surface**:

1. Stabilization is not change-proportional. Every `stabilize` walks the
   whole necessary graph — measured 260 ms for a 100k-node graph in which
   *nothing* changed (probe B). Jane Street incremental visits only nodes
   downstream of a change via a height-ordered recompute heap. User-function
   recomputation *is* change-proportional in Eta Signal (probe B,
   `recompute_count` tracks the changed half-graph only), so the deficit is
   traversal and bookkeeping, not wasted user work. Above ~10k necessary
   nodes, per-stabilize cost becomes the dominating design constraint.

2. The public surface is much smaller than incremental's: no collection-fold
   family (`array_fold`, `unordered_array_fold`, `sum`), no `freeze`, no
   `if_`/`join`/`bind2..4`, no `for_all`/`exists`, no dynamic cutoffs, no
   `memoize`, no `Expert` user-node API, no virtual clock combinators
   (`step_function`, `snapshot`), and no infix operators. Some exclusions are
   deliberate and evidence-backed (`map10+`, public `Expert`, first-class
   graphs — see the negative compile-fail suite); most are unmarked gaps.

On code quality, the library is **well-tested but over-built**. The test
infrastructure is unusually strong (state-machine model tests with generated
graphs, a fault-injection overflow harness, a compile-fail negative suite, a
1M-entry deterministic complexity gate for `eta_signal_map`). Against that,
the implementation carries a ~10.8k-line generic support layer instantiated
exactly once, five dead functors, and an `Obj`-based private extension seam —
roughly twice the code the algorithms need.

`eta_signal_map` is the best-engineered part of the surface: a clean-room
weight-balanced persistent map whose ancestry-skipping diff is
asymptotically *better* than the `Base.Map.symmetric_diff` that `incr_map`
relies on, with a real complexity gate. Its operator surface is, however, a
small fraction of `incr_map`'s (~1 of ~45 operator families).

No P0 (correctness) findings. Four P1 findings: change-proportional
scheduling (F1), the missing `Expert`-class extension surface and its
kernel/Obj-seam consequences (F2), the unregistered law-bearing prose in
`eta_signal.mli` (F3), and missing observer lifecycle events
(`Invalidated`/`Unnecessary`) in the public update stream (F4).

## 2. Methodology

Axes (settled with the requester): API surface parity, semantic parity, and
internals/architecture, in both directions (gaps in Eta Signal, and Eta-only
machinery graded on its own merits). Tests, benches, and the law registry
(LAWS.md) are graded targets.

Evidence standard: every claim cites `file:line` on the Eta side and the
reference side; claims that are high-impact and not already settled by
existing tests were verified with executable probes under `probes/`
(separate Dune project per repo policy, built and run via the Nix OxCaml
gate against the installed current worktree, `EIO_BACKEND=posix`).

Probes:

- `probes/probe_depth.ml` — single-chain graphs, 1k → 1.6M nodes, one set +
  stabilize. Raw output: `probes/results-depth.txt`.
- `probes/probe_scale.ml` — two-source multi-chain graphs, 200 → 100k
  necessary nodes; measures `recompute_count` deltas and per-stabilize wall
  time for changing, no-op, and idle stabilizations. Raw output:
  `probes/results-scale.txt`.

Deliberateness discipline: gaps are marked **[deliberate]** only with
positive evidence — a negative compile-fail fixture
(`test/signal/negative/`, `test/signal_map/negative/`), an ADR
(`docs/adrs/0004-...`), or a wayfinder issue. Unmarked gaps are listed as
gaps.

## 3. API completeness matrix

Legend: ✅ present · 🔶 partial/different · ❌ missing · 🚫 deliberate
exclusion (evidence cited) · ➕ Eta-only, no incremental analog.

### 3.1 Core constructors (`incremental_intf.ml` vs `lib/signal/eta_signal.mli`)

| Incremental | Eta Signal | Status | Notes |
| --- | --- | --- | --- |
| `const` / `return` | `const` | 🔶 | No `return` alias; `const` only (mli:375). |
| `map` | `map` | ✅ | Both take a cutoff argument (`?cutoff` vs `?equal`). |
| `map2`–`map9` | `map2`–`map9` | ✅ | Same arity ceiling. |
| `map10`–`map15` | — | 🚫 | `test/signal/negative/map10_negative.ml`. |
| `bind` | `bind` | ✅ | Same shape. |
| `bind2`–`bind4` | — | ❌ | Multi-source binds need manual nesting. |
| `join` | — | ❌ | Encodable as `bind s Fun.id`; incremental gives `Join` dedicated node kinds (`kind.ml`). |
| `if_` | — | ❌ | Encodable via `bind`; incremental's dedicated two-node `If_test_change`/`If_then_else` avoids selector re-runs (`state.ml:744`). |
| `both` | `both` | ✅ | |
| `all` | `all` | ✅ | List version; whole-list recompute per child change on both sides. |
| `for_all` / `exists` | — | ❌ | Boolean array folds. |
| `array_fold` | — | ❌ | O(1)-per-change n-ary fold (`array_fold.ml`). |
| `reduce_balanced` | — | ❌ | Balanced reduction tree. |
| `unordered_array_fold` / `opt_unordered_array_fold` | — | ❌ | Change-proportional fold with per-child update hooks (`unordered_array_fold.ml`); no Eta analog. |
| `sum` / `opt_sum` / `sum_int` / `sum_float` | — | ❌ | Incremental numeric aggregations. |
| `depend_on` | — | ❌ | Dependency without value use. |
| `necessary_if_alive` | — | ❌ | Keeps a node necessary while alive. |
| `freeze` | — | ❌ | Value latching with `?when_` (`state.ml:737`). |
| `lazy_from_fun` | — | ❌ | Trivial glue. |
| `memoize_fun` / `weak_memoize_fun` (+ `memoize/` sub-library with LRU stores) | — | ❌ | No memoized bind at any level. |
| `Let_syntax` / `Infix` (`>>=`, `>>\|`) | — | ❌ | No infix surface at all in `eta_signal.mli`. |
| `Scope` (`top`/`current`/`within`/`is_top`) | internal only | 🚫 | `test/signal/negative/public_scope_negative.ml`. |

### 3.2 Vars, observers, stabilization

| Incremental | Eta Signal | Status | Notes |
| --- | --- | --- | --- |
| `Var.create` / `set` / `watch` / `value` | same | ✅ | Eta `set` is effectful with typed `` `Reentrant_update`` (mli:306); incremental's plain `set` defers during stabilization (`state.ml:1289`). Both defer in-cycle sets. |
| `Var.latest_value` | — | ❌ | Last stabilized value accessor. |
| `Var.replace` | `Var.update_effect` | 🔶 | Eta's is effectful with reentrancy guard — arguably safer (mli:314). |
| `observe` | `Observer.observe` | ✅ | Eta adds typed observer errors and `?equal`. |
| `Observer.value` / `value_exn` | `Observer.read` / `unsafe_read_exn` | 🔶 | Eta's typed `observer_read_error` is richer than `Or_error`. |
| `Observer.on_update_exn` | callback at `observe` | 🔶 | Eta observers always have a callback; see F4 for the update-type gap. |
| `on_update` (node-level) | — | ❌ | Incremental can attach handlers to any node (`incremental_intf.ml:1558`). |
| `Observer.disallow_future_use` | `Observer.dispose` | 🔶 | Eta disposal is idempotent and lifecycle-typed (mli:364). |
| `~should_finalize` (GC observers) | — | ❌ | Explicit dispose only; consistent with Eta's scoped-resource discipline. |
| `Update.t` = `Necessary`/`Changed`/`Invalidated`/`Unnecessary` | `Initialized`/`Changed` | 🔶 | F4: no lifecycle events in the delivery stream. |
| `stabilize` | `stabilize` | ✅ | Eta: effectful, typed `stabilize_error`, transactional. |
| `am_stabilizing` | — | ❌ | No public reentrancy probe. |
| `Cutoff` module (`always`/`never`/`phys_equal`/`of_compare`/`of_equal`/`create`) | `?equal` args | 🔶 | F12: fixed at creation; no `set_cutoff`/`get_cutoff`. |
| `is_const` / `is_valid` / `is_necessary` | — | ❌ | Partially observable via `to_dot`/`stats`. |
| `node_value` | — | ❌ | Debug value access; `unsafe_read_exn` is observer-level. |
| `user_info` / `set_user_info` / graphviz attrs | — | ❌ | `to_dot` has no user labels. |
| `save_dot` | `to_dot` | 🔶 | Eta returns a string with scope/metadata options (mli:569). |
| `State.stats` (14 constant-time counters) | `stats` | 🔶 | Different field set; Eta adds lane/stream/keyed gauges; no `max_height_seen` (no heights). |
| `max_height_allowed` config | — | ➕/❌ | N/A architecturally; see §5.5. |
| `Expert` (`Dependency`/`Node`/`make_stale`/`invalidate`/`add_dependency`/`do_one_step_of_stabilize`) | private `Extension` only | 🚫 | ADR 0004 rejected a public extension API; see F2. |

### 3.3 Time

| Incremental (`Clock`) | Eta Signal (`Time`) | Status | Notes |
| --- | --- | --- | --- |
| `advance_clock` / `watch_now` (virtual clock) | real monotonic clock only | ❌ | Eta samples `Runtime_contract.now_ms`; deterministic tests still possible via `Eta_test.with_test_clock`. |
| `at` / `after` → `Before_or_after.t` | `Time.deadline` / `Time.after` → `bool signal` | 🔶 | Demand-owned daemon timers; never call `stabilize` (mli:589-607). |
| `at_intervals` | `Time.interval` | 🔶 | Tick counter with arithmetic catch-up; no alarm-precision model. |
| `step_function` | — | ❌ | Piecewise-constant function of time from a history list. Eta `Time.step` is a tick fold — a different combinator. |
| `incremental_step_function` | — | ❌ | |
| `snapshot` (time travel) | — | ❌ | Reconstruct an incremental's value at a past time. |
| timing wheel (shared) | per-timer daemon fiber | ➕ | §5.4 trade-off. |

### 3.4 `incr_map` vs `eta_signal_map`

`incr_map` operator families (src/incr_map_intf.ml, ~45 public operators plus
the `collate*`/`incr_set`/`erase_key`/`counting_multi_set` sub-libraries)
against `Eta_signal_map.Make(...).Keyed`:

| incr_map | eta_signal_map | Status | Notes |
| --- | --- | --- | --- |
| `mapi'` (per-key incremental children) | `Keyed.mapi` | ✅ | The one overlapping operator; §5.6 compares implementations. |
| `mapi` / `filter_mapi` / `filter_map` / `map` (whole-map diffed recompute) | — | ❌ | Cheap non-incremental-children variants. |
| `filter_mapi'` / `filter_map'` / `map'` | — | ❌ | Keyed filter variants. |
| `partition_mapi` / `partition_mapi'` | — | ❌ | |
| `unordered_fold` (+ `_with_extra`, `_nested_maps`) | — | ❌ | Change-proportional map folds. |
| `cutoff` | `?data_cutoff` | 🔶 | Eta: per-child data cutoff only (mli:123); incr_map has map-level and per-key cutoffs. |
| `merge` / `merge_both_some` / `merge_disjoint` / `merge'` | — | ❌ | |
| `unzip` / `unzip_mapi` / `unzip_mapi'` / `unzip3_mapi'` | — | ❌ | |
| `flatten` / `join` / `separate` | — | ❌ | Nested-map combinators. |
| `keys` | — | ❌ | |
| `rank` / `subrange` / `subrange_by_rank` | — | ❌ | Rank-based windowing. |
| `rekey` / `index_by` / `index_byi` | — | ❌ | |
| `transpose` / `collapse` / `collapse_by` / `expand` | — | ❌ | |
| `counti` / `count` / `for_all(i)` / `exists(i)` / `sum` | — | ❌ | |
| `mapi_count` / `map_count` / `mapi_min` / `mapi_max` / `map_min` / `map_max` / `min_value` / `max_value` / `mapi_bounds` / `map_bounds` / `value_bounds` | — | ❌ | Min/max/bounds family. |
| `observe_changes_exn` | — | ❌ | Diff-as-events. |
| `cartesian_product` | — | ❌ | |
| `Lookup` module | — | ❌ | Point-query sub-graphs. |
| `collate` (+ `collate_protocol`, `collate_shared`, `collate_reference`) | — | ❌ | Sorted/filtered/ranked views. |
| `incr_set` / `erase_key` / `counting_multi_set` | — | ❌ | |
| `of_set` | — | ❌ | |
| `Instrumentation` | `keyed_stats` | 🔶 | Eta's ten keyed gauges/counters (mli:174). |
| (persistent map type from `Base`) | `Eta_signal_map.Map` | ➕ | Clean-room persistent WBT with ancestry-skipping diff — §5.6; asymptotically better than `Base.Map.fold_symmetric_diff` for shared-ancestry workloads. |

## 4. Semantic parity deltas

Each row names the behavior, the reference contract, the Eta contract, and
the verdict. "Parity" means the audit found no observable difference within
the stated observation boundary.

| # | Behavior | Jane Street incremental | Eta Signal | Verdict |
| --- | --- | --- | --- | --- |
| S1 | Glitch freedom within one stabilization | Height-ordered recompute heap guarantees children settle before parents (`recompute_heap.ml`). | Pull-based DFS with per-generation stamps; shared dependencies computed once per generation (`kernel:1832-1974`, `eta_signal_graph.ml:759-786`). Diamond covered by `test_diamond_trace_matches_model`. | Parity (different mechanism). |
| S2 | Work per stabilization | O(dirty nodes + edge checks): heap holds only stale parents (`state.ml:984-1128`). | O(necessary graph): every stabilize recomputes necessary sets, walks observer roots, prunes the weak registry, re-plans binds. Probe B: 260 ms at 100k nodes, idle = no-op = changing within noise. | **Delta — F1.** |
| S3 | User-function recomputation | Only nodes whose children passed cutoff (`maybe_change_value` cutoff gate, `state.ml:984`). | Version-vector check per node skips unchanged subgraphs (`kernel:1861-1867`, `eta_signal_graph_algorithms.ml:508-521`). Probe B: single-var set recomputes only the dependent half-graph (50501 of 100k nodes at N=100k). | Parity. |
| S4 | Bind switch condition | `Bind_lhs_change` fires when the lhs value passes its cutoff (`state.ml:687`). | Switch iff `not (source.equal previous new)` — the source signal's cutoff (`eta_signal_bind.ml:190-200`). | Parity. |
| S5 | Old bind branch disposal | Default: invalidate all nodes created on rhs (`invalidate_nodes_created_on_rhs`, `state.ml:460`). Optional **rescope** mode reparents them (`bind_lhs_change_should_invalidate_rhs`, `state.ml:476`). | Always invalidate: old scope invalidated at commit (`kernel:1393-1397`, `eta_signal_bind.ml:356-368`). | **Delta — F13.** No rescope option; branch-flapping rebuilds shared sub-graphs. |
| S6 | Bind cascade convergence | Height adjustment makes rhs of nested binds visible in the same stabilization (`adjust_heights_heap.ml`). | Explicit fixpoint loop `plan_staged_bind_switches` recomputes bind nodes in scope-depth order until no new plans (`kernel:2422-2455`). Covered by `test_nested_bind_churn_trace_matches_model`. | Parity (Eta's loop is O(binds × graph) worst case — folded into F1). |
| S7 | Failed bind switch (selector raises / invalid inner) | Exception propagates out of stabilize; graph unchanged. | New scope invalidated (`eta_signal_bind.ml:202-218`), staged values rolled back; snapshot preserved. Covered by `test_pure_failure_matches_model`. | Parity. |
| S8 | Var set during stabilization | Queued on `set_during_stabilization` stack, applied next cycle (`state.ml:1276-1309`). | Accepted, "published by a later explicit stabilization" (mli:306-312). Covered by `test_observer_phase_mutation_matches_model`. | Parity. |
| S9 | Observer delivery ordering | LIFO stack of nodes with handlers (`handle_after_stabilization`, `state.ml:1332`); no topological guarantee. | Deterministic graph order: observers sorted by dependency reachability then id (`kernel:2399-2405`, `eta_signal_graph.ml:821-825`). | Eta stronger. |
| S10 | Observer delivery coalescing | Handlers fire once per stabilization per node with the final update. | Delivery cursor (`eta_signal_observer.ml:242-331`) retries failed deliveries next stabilize and coalesces blips: a pending delivery whose value returned to the last delivered one is acked without a callback (mli:556-565). Covered by `test_observer_failure_retry_matches_model`. | Eta richer (typed failure + retry semantics). |
| S11 | Observer lifecycle events | `Update.t` includes `Invalidated` and `Unnecessary`. | `Initialized`/`Changed` only; invalidation visible via `Observer.read` errors (mli:352-358). | **Delta — F4.** |
| S12 | Rollback of failed stabilization | Stabilization is not transactional; a defecting node function aborts the pass mid-flight (nodes already recomputed keep new values). | Staged-cell transaction: preflight → commit; failures before commit leave the previous snapshot and keep source updates retryable (mli:543-551; `eta_signal_transaction.ml`, `eta_signal_stabilization_pass.ml:274-333`). Covered by `test_pure_failure_matches_model`, `test_dynamic_cycle_preserves_snapshot_matches_model`. | Eta stronger. |
| S13 | Deep graphs | Errors above `max_height_allowed` (default 128; `incremental_intf.ml:1043`). | Pull recursion on the OCaml stack. Probe A: 1.6M-node chain stabilizes fine (ulimit -s 8192). | Eta stronger in practice; bound is implicit rather than configurable. |
| S14 | Counter overflow | Heights bounded by config; other counters unbounded. | All public counters monotone, non-wrapping; overflow is a typed `` `Counter_overflow`` failure before partial publication (mli:148, 552-555). Fault-injection harness `test/signal/eta_signal_overflow_harness.ml` forces every overflow path. | Eta stronger. |
| S15 | Cutoff dynamism | `set_cutoff`/`get_cutoff` at runtime; specialized variants (`cutoff.ml`). | `?equal` fixed at node creation. | **Delta — F12.** |
| S16 | Cross-domain safety | Single-threaded; no domain fence. | Single-domain fence: `Invalid_argument` from other domains and runtime worker callbacks (mli:98-106; `eta_signal_graph.ml:280-288`). Cross-domain consumption offered explicitly via the `Stream` bridge (mli:702-742). | Different (Eta's fence is a feature given OCaml 5 domains). |
| S17 | Cycle detection | Structurally impossible (heights). | `computing` flag raises `` `Cycle`` (`kernel:1839`); dynamic-cycle test coverage exists (`test_dynamic_cycle_preserves_snapshot_matches_model`). | Parity. |

## 5. Internals comparison

### 5.1 Node representation

Incremental (`node.ml:8-100`): 25 mutable fields, cache-ordered ("Don't
change the order of these nodes without performance testing"), intrusive
doubly-linked heap links, `parent0` + `parent1_and_beyond` optimization for
the one-parent case, child/parent index arrays for O(1) edge removal,
`or_null` and `Uniform_array` throughout, optional creation backtraces.

Eta Signal (`kernel:442-458`): a flat record with list-based
`dependencies`/`dependents`, a staged snapshot cell carrying a version and a
dependency-version vector, generation stamps, scope pointer, timer slot.
Attach/detach are `List.filter`/`List.exists` scans (`eta_signal_graph.ml:
666-703`) — O(fan-in) per edge op and O(n²) to build or tear down a wide
node (e.g. `all` over 10k signals). No physical-layout engineering.

Assessment: honest, simple, allocation-heavier. The version-vector design
buys change-proportional *recomputation* without heap maintenance, but the
list edges and per-node version lists make wide graphs quadratically
expensive to mutate.

### 5.2 Scheduling

Incremental: height-indexed array of intrusive lists (`recompute_heap.ml`),
O(1) add/remove-min, immediate-recompute fast paths for single-child parents
(`state.ml:1062-1122`), adjust-heights heap for bind (`adjust_heights_heap.ml`).

Eta Signal: pull DFS from observer roots with generation stamps; necessity
recomputed by full reachability from observer roots every stabilization
(`eta_signal_graph.ml:1817-1825`); bind planning as a separate fixpoint pass
with repeated full invalidation scans (`kernel:2422-2455`,
`kernel:1431-1448`); timer demand computed by scanning *all live nodes*
(`kernel:1648-1658`, `eta_signal_graph.ml:1840-1848`).

Assessment: the dominant architectural gap (F1). Every ingredient of Eta's
loop is individually correct; the composition is O(necessary) per
stabilization with superlinear constants (probe B: ×500 nodes → ×1150 wall
time), and there is no scale gate that would have caught it (§7.4).

### 5.3 Bind lifecycle

Incremental splits a bind into `Bind_lhs_change` + `Bind_main` nodes joined
by a scope; switching rewires edges via index arrays and either invalidates
or rescopes the old rhs. Eta keeps one `Bind` node with a staged snapshot;
switching stages the new inner + scope and defers invalidation to a commit
preflight that must first *predict* which staged nodes the invalidation will
kill (`kernel:1419-1448`, `kernel:1660-1698`) so their staged values are not
committed. Correct, but the prediction pass re-runs full scope collections
after every bind compute inside the fixpoint loop.

### 5.4 Timers

Incremental: one shared `Timing_wheel` inside the state, advanced when the
user advances the virtual clock; alarms are ordinary nodes made stale
(`state.ml:130-145`). Eta: one **daemon fiber per timer signal**, sleep-wake
loop with generation-guarded 5-state lifecycle (`eta_signal_timer.ml:269-361`,
`eta_signal_timer_policy.ml:6-11`), demand-owned (started when the signal
becomes necessary, stopped when not), plus a stabilization-time coalesced
clock sample shared by all timer sources (mli:594-600).

Assessment: Eta's design is real-time and demand-driven (a genuine ➕ for
long-lived apps that want timers without a clock driver), at the cost of one
fiber per live timer and ~2.8k lines of timer machinery (timer.ml 978 +
timer_policy.ml 813 + timer sections of kernel). No `step_function`, no
`snapshot`, no virtual clock combinator layer.

### 5.5 What the height cap comparison actually shows

Incremental's `max_height_allowed` (default 128) is not a robustness
feature; it is a scheduling-structure invariant. Eta has no heights, hence
no cap; probe A shows the practical depth limit is the OCaml stack, which
comfortably exceeds 1.6M frames here. Net: Eta is *more* forgiving on deep
graphs, *less* instrumented (`max_height_seen` has no analog).

### 5.6 Keyed maps

`incr_map`'s per-key `mapi'` is built **on the public `Expert` API**
(`incr_map.ml` `generic_mapi'`: `E.Node.create`, `E.Node.make_stale`,
`E.Node.remove_dependency`). `eta_signal_map`'s `Keyed.mapi` cannot use that
route — ADR 0004 rejected a public extension API — so the reconciliation
engine lives **inside the kernel** (`compute_keyed`, `kernel:1976-2122`) with
a private `Extension` seam (`kernel:3569-3716`) that passes `Obj.t` tokens to
the sibling package (`eta_signal_map_api.ml:78-103`).

The data structure comparison inverts in Eta's favor: `incr_map` relies on
`Base.Map.fold_symmetric_diff` (O(n) per change), while
`eta_signal_map_kernel.ml` implements a clean-room weight-balanced persistent
map whose cursor diff skips shared ancestry — O(min(n, k·log(n+1)))
comparisons for k persistent edits (mli:101-109), enforced by a deterministic
1M-entry gate (`bench_signal_map.ml:50`, `gate_limits` at :206). The WBT
balance constants (Δ = 5/2, Γ = 3/2; `eta_signal_map_kernel.ml:44-45`) follow
Nievergelt–Reingold/Hirai–Yamamoto and are pinned by
`map_kernel_invariants_survive_edits` in `test/laws/`.

Assessment: Eta's keyed *engine* is excellent and better-gated; the
*architecture* that forced it into the kernel behind an `Obj` seam is the
problem (F2).

## 6. Eta-only machinery, graded on its own merits

| Component | Grade | Notes |
| --- | --- | --- |
| `eta_signal_transaction` + `eta_signal_stabilization` | Good | Small, single-purpose, phantom-phased state machines; the cleanest modules in the package. Single user, but the abstraction pays for itself (S12). |
| `eta_signal_lane` | Adequate, costly | Hand-rolled fair FIFO cancellable fiber mutex with waiter compaction and reentrancy by owner-fiber + fiber-local depth (311 lines). Careful cancellation handling (`eta_signal_lane.ml:209-257`). Question worth an invariant: which lane property (fairness? cancellation? reentrancy?) actually justifies not using an Eta core primitive; none is stated. |
| Observer delivery state machine | Good, dense | Claim/run/ack/release cursor implementing the documented coalescing (S10). `eta_signal_observer.ml` is the hardest file to review and the one most dependent on its own prose — exactly the prose missing from the law registry (F3). |
| Timer stack | Adequate, over-layered | Pure policy state machine is clean; the `Adapter`/`node`/plan-record layers above it (§6.1) cost more than they return. Per-timer daemon fibers are defensible; the demand-refresh-on-pull path (`refresh_node_on_demand`) is subtle and covered by dedicated timer tests. |
| `Stream` bridge | Good | Bounded dropping queue with careful ack/drop accounting and cross-domain consumption (mli:702-742; `kernel:19-213`). Genuinely Eta-shaped (typed errors, resource cleanup via `with_observed`). |
| `to_dot` + `stats` | Good | Rich, read-only, bounded tombstones; keyed gauges registered as SD01–SD15. |
| `Graph_error` taxonomy + overflow discipline | Good | Typed failures everywhere; non-wrapping counters with a fault-injection harness (S14). |

### 6.1 The support-layer over-abstraction (headline smell)

Around the kernel sits a generic engine layer: `eta_signal_graph.mli`
(1018 lines, one 11-parameter abstract `t`, ~100 values), `eta_signal_observer.mli`
(275 lines of 5–7-parameter "port" records), `eta_signal_timer.mli` /
`eta_signal_timer_policy.mli` (689 lines of plan/state records),
`eta_signal_bind.mli` (155 lines of 6-parameter contexts),
`eta_signal_stabilization_pass.mli` (210 lines of per-phase plan records).

Every one of these generic interfaces is instantiated **exactly once**, by
the kernel. The pattern is consistent: a record of closures is built at the
call site, passed one level down, and immediately destructured — e.g.
`stabilization_pending_mark_release` is a thunk in a one-constructor box
(`eta_signal_graph.ml:1334-1346`), `snapshot_commit_plan` a two-thunk record
(`eta_signal_graph.ml:175-184`), and `Eta_signal_stabilization_pass.pure_*_plan`
five records that wrap five closures called once each
(`eta_signal_stabilization_pass.ml:46-98`). The `.mli` itself warns "there is
currently exactly one adapter … not an invitation to add more copied test
seams" (`eta_signal_graph.mli:8-13`) — the generality was built first and
its justification never arrived.

Measured cost: the support layer is ~10.8k lines for what is, algorithmically,
a graph engine, a delivery cursor, a timer policy, and a bind switch — the
kernel that does all four is 3.7k lines. The indirection also *hides* the
O(necessary)-per-stabilize economics: each individual hop looks free.

This is the single largest maintainability finding (F5): not wrong, just
roughly 2× the necessary code, concentrated exactly where a newcomer must
read first.

### 6.2 Dead generic functors

`eta_signal_graph_algorithms.ml` exports seven functors/modules for general
graph work; five are never instantiated anywhere in the repo:
`Make_dirty` (:293), `Make_versions` (:191), `Make_order` (:158),
`Make_compute` (:327), `Make_reachable` (:58). Their logic is duplicated
inline inside `eta_signal_graph.ml` (`remember_compute`,
`same_version_snapshot`, `order_depends_on`, `fold_reachable`,
`mark_dirty_recording_previous`). Only `Make_edges` is used (once,
`kernel:700`). ~250 dead lines plus interface surface (F6).

### 6.3 The `Obj` extension seam

`Extension.keyed_entry_identity` uses `Obj.magic` on the caller's key and
`Obj.repr`/`Obj.obj` for scope/source/signal tokens
(`kernel:3625-3656`). A wrong token is undefined behavior, not an error —
against the repo's "break loudly" rule. It is private-CMI-only and exercised
by `test/signal_map/keyed_private/`, but the type-safety hole is real and
exists only because of the architecture described in §5.6 (F7).

### 6.4 Minor smells

- `saturating_succ` redefined in four files; `add_int_capped` in two
  (`kernel:311-315`, `eta_signal_graph.ml:347-353`, `eta_signal_lane.ml:58`,
  `eta_signal_timer_policy.ml:178-194`).
- `Stream_bridge` (213 lines) lives at the top of the kernel file before
  `Make`, with its own module aliases — a standalone module in waiting.
- `eta_signal_map_kernel.ml` uses `Obj.magic old_map` for the physical-no-op
  shortcut in `map`/`filter_mapi` (:177-204). Sound (all payloads physically
  identical implies the cast is identity), and it is the standard Base trick,
  but worth one comment per site rather than zero.
- `Map.of_list` does `mem` + `set` per binding — two traversals
  (`eta_signal_map_kernel.ml:154-160`); fine at current sizes.
- `Eta_signal_map.Make` re-instantiates `Eta_signal_kernel.Make`
  (`eta_signal_map_api.ml:41`): `Eta_signal.Make(E)()` and
  `Eta_signal_map.Make(E)()` produce *different graphs* with incompatible
  `signal` types. ADR-sanctioned, but the "sibling package" is really a
  superset functor; the two-graphs footgun needs one sentence in
  `eta_signal_map.mli` (F10).

## 7. Tests, benches, and the law registry

### 7.1 Test strengths (unusually good)

- **State-machine model tests** (`test/signal/model/test_eta_signal_model.ml`,
  3556 lines): explicit pending-vs-committed model with scripted traces for
  coalesced sets, effectful updates, observer failure retry, pure failure,
  dynamic cycles, dispose demand, bind branch demand, nested bind churn,
  retained branches, diamonds, stream bridge — plus generated-graph traces
  (`test_generated_small_graphs_match_model`, `test_generated_larger_graphs_match_model`)
  and a fuzz driver (`fuzz_eta_signal_model.ml`).
- **Contract suite** (`test/signal/contract/test_eta_signal_contract.ml`,
  2344 lines): typed-failure/defect boundaries, cross-domain and
  worker-context fences.
- **Fault-injection overflow harness** (`test/signal/eta_signal_overflow_harness.ml`):
  forces every counter to `max_int` and checks the typed `` `Counter_overflow``
  path. Rare and valuable.
- **Compile-fail negative suite** (`test/signal/negative/`,
  `test/signal_map/negative/`, `run.sh`): pins the *deliberate* boundary —
  no `map10`, no public `Expert`, no first-class/global graphs, no public
  scopes, no cross-graph keyed children. This suite is what lets this audit
  distinguish "missing" from "deliberate"; more libraries should have one.
- **Deterministic complexity gate** (`lib/signal_map/bench/bench_signal_map.ml`):
  insertions/removals/data changes/mixed/child-only/independent controls up
  to 1M entries, bounding key comparisons and child visits (`--gate`).

### 7.2 Test gaps

- Generated graphs are small (30 nodes, 8 observers, 120 steps;
  `test_eta_signal_model.ml:3212-3220`). Nothing exercises the core engine
  beyond a few hundred nodes — exactly the regime where F1 lives.
- `test/signal/kernel/test_eta_signal_kernel.ml` (82 lines) covers only the
  `Extension` seam. The 3.7k-line kernel is covered end-to-end only — no
  direct unit tests for transaction staging, generation bookkeeping, or the
  bind fixpoint planner.
- No scale/complexity gate for the *core* engine. `lib/signal/bench/bench_signal.ml`
  is a micro toy (one static diamond vs `Mutable_ref`); probe B's table is
  the first measurement of per-stabilize scaling.
- Timer suites are deep on policy (`test_eta_signal_timer_policy.ml`,
  1270 lines) but nothing measures daemon behavior under many concurrent
  timers.

### 7.3 Law registry (LAWS.md)

`.scratch/research/dx/e22/review/LAWS.md` registers `eta_signal_map` claims
(SM01–SM08+), the keyed operator (SMKEY/SMTXN rows), keyed diagnostics
(SD01–SD15, the only rows citing `lib/signal/eta_signal.mli`), and the
private extension protocol. **The core `eta_signal.mli` does not appear in
the census totals table at all** (LAWS.md:616-641), despite carrying the
densest law-bearing prose in the repo: stabilization transactionality
(mli:543-565), observer delivery coalescing (mli:328-350, 556-565), bind
scope semantics (mli:524-541), timer coalescing/catch-up (mli:589-699),
stream drop semantics (mli:702-742). The repo's prospective rule requires a
named test and registry row (or dated debt) per claim in the same change;
much of this prose already *has* executable coverage in the model/contract
suites and only needs registration — the rest needs properties or dated
debt (F3).

## 8. Ranked findings register

Priorities: **P1** = significant capability/architecture gap or repo-policy
violation; **P2** = quality/maintainability. No P0 (correctness) findings:
everything the audit could check against the reference held (§4).

Corrections are phrased as EARS requirements or invariants, per the settled
handoff format; code sketches appear only where a contract needs defining.

### F1 — P1 — Stabilization is not change-proportional

- **Location**: `lib/signal/kernel/eta_signal_kernel.ml:2540-2645` (driver),
  `eta_signal_graph.ml:1817-1848` (necessity + timer demand by full
  reachability / full live-node scan), `kernel:2422-2455` (bind fixpoint with
  repeated invalidation scans).
- **Evidence**: probe B (`probes/results-scale.txt`): idle/no-op/changing
  stabilize cost the same within noise at every size; 260 ms at 100k nodes;
  superlinear growth (×500 nodes → ×1150 wall time). Reference: dirty-driven
  recompute heap (`.reference/incremental/src/state.ml:1113-1128`,
  `recompute_heap.ml`).
- **Impact**: per-stabilize cost is bounded by total graph size, not change
  size; interactive/latency-sensitive use caps out around ~10k necessary
  nodes. No test or bench would ever catch it (§7.2).
- **Correction (EARS)**: When a stabilization begins, the system shall
  schedule recomputation work proportional to the set of nodes whose inputs
  changed since the previous stabilization, and shall not traverse nodes
  that are neither dirty nor downstream of a dirty node. **Invariant**:
  for any stabilization in which no source var value passed its cutoff,
  stabilization completes without visiting more than O(1) graph nodes.
  **Gate**: a deterministic bench (shape of `bench_signal_map.ml --gate`)
  shall bound per-stabilize visited-node counts for noop/single-change
  workloads at 10k and 100k nodes.

### F2 — P1 — No `Expert`-class extension surface; keyed engine embedded in kernel behind an `Obj` seam

- **Location**: ADR `docs/adrs/0004-...:33-34` (rejected public extension
  API); engine `kernel:1976-2122`; seam `kernel:3569-3716`;
  `Obj.magic`/`Obj.repr`/`Obj.obj` at `kernel:3631-3656`.
- **Evidence**: `incr_map`'s per-key `mapi'` is a *library* built on
  `Incremental.Expert` (`.reference/incr_map/src/incr_map.ml`,
  `generic_mapi'`); the ADR's alternative placed the engine in-kernel.
- **Impact**: the kernel does two jobs (3.7k lines); the private seam needs
  unchecked casts (F7); future keyed/incremental data structures must
  modify the kernel instead of linking a library.
- **Correction (EARS)**: The system shall provide a public, type-safe node
  extension interface that allows library code to define custom node kinds
  with custom stale/recompute behavior and dynamic dependencies, without
  `Obj` and without widening the graph's public mutation surface. If ADR
  0004's rejection stands, the ADR shall be amended to record the measured
  costs (kernel size, `Obj` seam, single-consumer keyed engine) as accepted
  consequences. **Invariant**: any value crossing a package boundary is
  typed; no `Obj.magic`/`Obj.obj` on the extension path.

### F3 — P1 — `eta_signal.mli` law-bearing prose is unregistered

- **Location**: `lib/signal/eta_signal.mli` (stabilize:543-565, observer
  coalescing:328-350/556-565, bind:524-541, Time:589-699, Stream:702-742);
  registry `.scratch/research/dx/e22/review/LAWS.md:616-641` (no
  `eta_signal.mli` rows beyond SD01–SD15).
- **Evidence**: census totals table omits the module; the prose spans are
  law-bearing per the repo's own definition.
- **Impact**: the repo's prospective law rule is unenforced on its densest
  contract; regressions in delivery coalescing or rollback semantics would
  not trip a named property.
- **Correction (EARS)**: Every law-bearing claim in `eta_signal.mli` shall
  have one registry row with an exact normative span and either a named
  executable test (existing model/contract tests may be *registered*, not
  duplicated) or dated debt with owner and follow-up. Open-ended omission is
  forbidden by the standing policy.

### F4 — P1 — Observer update stream has no lifecycle events

- **Location**: `lib/signal/eta_signal.mli:167-172` (`Initialized`/`Changed`
  only); reference `incremental_intf.ml:1525-1532`
  (`Necessary`/`Changed`/`Invalidated`/`Unnecessary`).
- **Evidence**: §4 S11.
- **Impact**: stream consumers (`Stream.observe`) cannot distinguish
  invalidation/disposal from quiescence; a UI binding learns about a dead
  branch only by polling `Observer.read` and failing.
- **Correction (EARS)**: When an observed signal is invalidated or becomes
  unnecessary, the system shall deliver a terminal lifecycle event through
  the observer's update channel before the observer's state changes are
  observable via `read`. (Compatibility note: per repo rules, old paths are
  deleted — extend `update`, update all callers, no shim.)

### F5 — P2 — Support-layer over-abstraction

- **Location**: §6.1; `eta_signal_graph.mli` (1018 lines, 11-parameter `t`),
  `eta_signal_observer.mli`, `eta_signal_timer{,_policy}.mli`,
  `eta_signal_bind.mli`, `eta_signal_stabilization_pass.mli`.
- **Evidence**: single instantiation for every generic interface; plan/port
  records that wrap single closures (cited §6.1).
- **Impact**: ~2× code at the exact seam newcomers read first; hides the F1
  economics behind free-looking hops.
- **Correction (EARS)**: Each generic interface in the support layer shall
  either have ≥2 distinct instantiations or be inlined into its single
  caller. **Invariant** (review checklist): no record-of-closures type is
  introduced to defer a call that a function parameter can express.

### F6 — P2 — Dead functors in `eta_signal_graph_algorithms`

- **Location**: `lib/signal/eta_signal_graph_algorithms.ml:58,158,191,293,327`
  (`Make_reachable`, `Make_order`, `Make_versions`, `Make_dirty`,
  `Make_compute`) and matching `.mli` surface.
- **Evidence**: repo-wide usage grep — only `Make_edges` instantiated
  (`kernel:700`).
- **Impact**: ~250 dead lines plus interface; duplicated logic drifts from
  the live copies in `eta_signal_graph.ml`.
- **Correction (EARS)**: Delete the five unused functors and their `.mli`
  entries in the same change (repo rule: delete old paths, no deprecation).

### F7 — P2 — `Obj` casts on the extension seam

- **Location**: `kernel:3625-3656` (`keyed_entry_identity`,
  `keyed_scope_valid`).
- **Evidence**: `Obj.magic key`, `Obj.repr scope`, `Obj.obj token` —
  unchecked; a wrong token is UB.
- **Impact**: private-CMI-only, but violates "break loudly"; exists solely
  because of the F2 architecture.
- **Correction**: folded into F2's type-safe extension interface; if F2 is
  deferred, tokens shall become existential GADT wrappers validated against
  the owner graph at use time, raising on mismatch.

### F8 — P2 — Collection-fold family missing

- **Location**: `eta_signal.mli` (absent); reference
  `incremental_intf.ml:1252-1360` (`array_fold`, `reduce_balanced`,
  `unordered_array_fold`, `sum*`).
- **Evidence**: §3.1; `all` recomputes the whole list per child change.
- **Impact**: no change-proportional fan-in aggregation; users hand-roll
  O(n) folds.
- **Correction (EARS)**: The system shall provide an n-ary fold whose
  per-child-change recomputation is O(1) amortized (unordered with update
  hooks) or O(log n) (balanced), with a complexity gate in the shape of
  `bench_signal_map.ml --gate`.

### F9 — P2 — Small-surface parity gaps

- **Location**: §3.1–3.3 rows marked ❌.
- **Evidence**: `if_`, `join`, `bind2..4`, `for_all`/`exists`, `depend_on`,
  `necessary_if_alive`, `freeze`, `Var.latest_value`, node-level
  `on_update`, `is_const`/`is_valid`/`is_necessary`, `node_value`,
  `set_cutoff`, `memoize*`, infix operators, `step_function`, `snapshot`.
  (`map10+`, public `Expert`, public scopes are 🚫 deliberate.)
- **Impact**: each is small; together they define whether Eta Signal is a
  faithful "incremental-style" library or a smaller reactive core. Several
  (`freeze`, `set_cutoff`, infix, `bind2`) are frequent-use items in
  incremental codebases.
- **Correction (EARS)**: For each row, the maintainers shall either add the
  operator with a named test and registry row, or record a dated, reasoned
  exclusion in the negative suite (the repo already has the mechanism:
  `test/signal/negative/`). **Recommendation batch 1** (cheap, high-value):
  infix operators, `if_`, `bind2`, `freeze`, `set_cutoff`.

### F10 — P2 — Two-graphs footgun between `Eta_signal.Make` and `Eta_signal_map.Make`

- **Location**: `lib/signal_map/api/eta_signal_map_api.ml:40-42`;
  ADR 0004.
- **Evidence**: `Eta_signal_map.Make(E)()` re-instantiates
  `Eta_signal_kernel.Make(E)()` — a fresh, incompatible graph.
- **Impact**: users holding `Eta_signal.Make` signals cannot use
  `Keyed.mapi`; the error is a type error at the boundary, not guidance.
- **Correction (EARS)**: `eta_signal_map.mli` shall state at module level
  that the functor creates an independent graph and that applications
  needing keyed collections shall apply `Eta_signal_map.Make` as their *only*
  graph functor.

### F11 — P2 — No rescope option for bind branches

- **Location**: `kernel:1393-1397`, `eta_signal_bind.ml:356-368`;
  reference `state.ml:460-487` (`bind_lhs_change_should_invalidate_rhs`,
  `rescope_nodes_created_on_rhs`).
- **Evidence**: §4 S5.
- **Impact**: branch-flapping workloads rebuild shared sub-graphs on every
  switch; incremental can reparent them.
- **Correction (EARS)**: When a bind switches and the old branch's nodes are
  valid in the new scope, the system shall offer a mode that rescopes rather
  than invalidates those nodes. (Needs a semantics decision: which nodes are
  eligible; incremental's answer is "all nodes created on the rhs".)

### F12 — P2 — Cutoffs are static and structurally poor

- **Location**: `eta_signal.mli` `?equal` args; reference `cutoff.ml`,
  `incremental_intf.ml:1573-1611` (`Cutoff` module, `set_cutoff`).
- **Evidence**: §4 S15; no `always`/`never`/`compare` variants; no runtime
  update.
- **Impact**: users rebuild nodes to change cutoffs; no escape hatch for
  "always propagate" debugging.
- **Correction (EARS)**: The system shall provide named cutoff constructors
  (`always`, `never`, `of_compare`, `of_equal`, `phys_equal`) and a guarded
  `set_cutoff` that fails when called during a pure stabilization phase.

### F13 — P2 — Missing scale gate for the core engine

- **Location**: `lib/signal/bench/bench_signal.ml` (micro only);
  contrast `lib/signal_map/bench/bench_signal_map.ml:50-330`.
- **Evidence**: §7.2; probe B is currently the only scaling measurement.
- **Impact**: F1-class regressions land silently.
- **Correction (EARS)**: The repo shall carry a deterministic core-engine
  complexity gate (visited nodes and per-stabilize work for noop,
  single-source-change, and bind-switch workloads at 1k/10k/100k nodes),
  wired like the signal-map gate (`--gate --emit`, CSV artifact).

### F14 — P2 — Micro-duplications and placement

- **Location**: §6.4 — `saturating_succ` ×4, `add_int_capped` ×2,
  `Stream_bridge` at kernel top.
- **Correction (EARS)**: One shared internal arithmetic helper; move
  `Stream_bridge` into its own `eta_signal_stream_bridge.{ml,mli}` under the
  private support library. No behavioral change.

## 9. Appendix

### 9.1 Observation boundaries

- Semantic parity (§4) was assessed at the observer/update boundary and, for
  lifecycle behavior, at `stats`/`to_dot`. Internal scheduling strategy is
  intentionally *not* a parity axis — economics are reported as F1, not as
  semantic divergence.
- `eta_signal_map` was compared against `incr_map` @ v0.18 preview; the
  persistent map itself against `Base.Map` semantics via the registry's own
  properties (SM01–SM08 in `test/laws/`).
- Probes ran one execution each on this workstation (OxCaml 5.2.0+ox,
  `EIO_BACKEND=posix`); wall-time numbers are indicative, not gates.

### 9.2 What was deliberately not audited

- `eta_par` / multi-domain signal use (single-domain fence is documented and
  tested; parallel signal graphs are out of the current contract).
- js_of_ocaml targets (OxCaml track does not build them; no signal JS tests
  exist).
- The `memoize/` and `step_function/` reference sub-libraries' internals
  beyond their public interfaces.

### 9.3 File inventory (audited in full)

Eta: `lib/signal/eta_signal.{ml,mli}`, `lib/signal/kernel/eta_signal_kernel.ml`,
`lib/signal/eta_signal_{graph,graph_algorithms,scope,transaction,lane,
stabilization,stabilization_pass,observer,bind,timer,timer_policy,error,
cleanup,debug,id}.{ml,mli}`, `lib/signal_map/**`, `lib/signal/bench/`,
`lib/signal_map/bench/`, `test/signal/**`, `test/signal_map/**`,
`test/laws/`, LAWS.md signal sections, ADR 0004, wayfinder
`eta-signal-keyed-map` maps.

Reference: `.reference/incremental/src/incremental_intf.ml` (2016 lines,
full), `node.ml`, `state.ml`, `kind.ml` (via state), `scope.ml`,
`recompute_heap.ml`, `adjust_heights_heap.ml`, `cutoff.ml`,
`memoize/src/incr_memoize.mli`, `step_function/` interfaces;
`.reference/incr_map/src/incr_map{,_intf}.ml` (3640 lines, full).
