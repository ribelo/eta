# Independent review — Eta Signal vs Jane Street Incremental

**Date:** 2026-08-04
**Review target:** the code packed in `eta-signal-audit-gptpro-complete-20260804-100948.md`
**Requested task:** independently verify F1–F14, challenge semantic-parity claims, search for missed correctness defects, and produce a ranked correction plan.

## 0. Scope, evidence standard, and limitations

This is an independent static trace through the packed implementation, not a restatement of `REVIEW.md`. I followed the affected paths in Eta Signal and, where material, the packed Jane Street `incremental` and `incr_map` sources.

Two limitations matter:

1. The bundle explicitly omits `test/signal/`, `test/signal_map/`, `test/laws/`, the law registry itself, and the reference tests. Therefore claims whose decisive evidence is a repository-wide grep, a registry census, or a named test can be verified only conditionally.
2. The packed code header identifies `master@4197be98`, while the embedded audit says its baseline and installed probe build were `master@5694938a` (`.scratch/research/eta-signal-incremental-audit/REVIEW.md:5-8`). I therefore treat the raw probe timings as corroborating evidence, not as measurements of the exact packed revision.

I did not compile or execute the code. New correctness findings below are static counterexample traces. Each should be converted into an executable regression test before a fix is merged.

## 1. Executive verdict

The audit is directionally strong on the large architectural facts, but it overstates three conclusions:

- F2 conflates “the keyed engine is embedded in the kernel” with “the production package boundary is `Obj`-typed.” The first is true; the second is not. The production `Keyed.mapi` path is typed. `Obj` is concentrated in private testing introspection.
- F4 says stream consumers cannot distinguish invalidation from disposal. They already can: disposal closes the queue cleanly, while dynamic-scope invalidation closes it with `` `Invalid_scope``.
- The audit’s “no P0” conclusion does not survive two concrete traces in the packed code.

### Final finding counts

| Result | Findings |
|---|---|
| **Confirmed** | F7, F8, F10, F12, F13 |
| **Amended** | F1, F2, F3, F4, F5, F6, F11, F14 |
| **Refuted as framed** | F9 |

### New findings

| ID | Priority | Summary |
|---|---:|---|
| **N1** | **P0** | Transaction-ID overflow mutates stabilization state to `Pure` before allocation fails, permanently wedging the graph. |
| **N2** | **P0** | A keyed removal can invalidate a nested bind owner and then commit that bind’s staged switch, attaching a new dependency to an invalid node and retaining invalid topology. |
| **N3** | **P1** | Observer callback ordering uses a comparator that is not a total order on dynamic graphs. |
| **N4** | **P1** | Wide fan-in construction and teardown are quadratic because edge attachment/removal scans lists. |
| **N5** | **P2** | The stabilization pass has one exception region spanning pre-commit and post-commit work; the intended non-failing commit tail is implicit rather than enforced by types. |

No additional confirmed P0 was found in the lane waiter protocol, observer delivery cursor, timer generation guards, weak registry, or ordinary cycle detection. That statement is limited to the packed code and static review.

---

## 2. Verification table — F1 through F14

### F1 — Stabilization is not change-proportional

**Verdict: AMENDED, central claim confirmed. Priority remains P1.**

#### Evidence

The audit understates the amount of unconditional work. Generation stamps prevent duplicate *computation* inside one stabilization, but not traversal:

- `compute_seen`/`compute_cached` reuse a node after it was reached in the current generation (`lib/signal/eta_signal_graph.ml:759-786`).
- Every reachability request creates a fresh `seen` table and recursively walks roots (`lib/signal/eta_signal_graph.ml:827-836`).
- `necessary_ids` first prunes/scans the weak live-node registry, then performs full root reachability (`lib/signal/eta_signal_graph.ml:1811-1825`).
- `timer_demand` scans all live nodes and independently recomputes root reachability (`lib/signal/eta_signal_graph.ml:1840-1853`).
- `post_commit_necessary_timers` repeats registry pruning and another root traversal (`lib/signal/eta_signal_graph.ml:1855-1866`).
- Before ordinary observer collection, bind planning repeatedly recollects all reachable bind nodes until a fixpoint (`lib/signal/kernel/eta_signal_kernel.ml:2407-2455`).
- Observer sorting is itself expensive: each comparison can run a dependency DFS (`lib/signal/eta_signal_graph.ml:808-825`; `lib/signal/kernel/eta_signal_kernel.ml:2399-2405`).

Thus one stabilization is not merely “one O(necessary) walk.” It combines multiple full scans and, with multiple observers or bind churn, superlinear comparison/fixpoint constants.

The packed probe supports the qualitative conclusion. At its largest reported shape, it records about 259–276 ms for no-op, changing, and idle stabilizations and 50,501 recomputations after changing one half of a nominal 100k-node graph (`probes/results-scale.txt:1-5`). However:

- `run_effect` creates a fresh Eio runtime for every set/stabilize call (`probes/probe_scale.ml:21-31`), adding a size-independent baseline;
- the printed `nodes = 2 * chains * len` omits watch nodes and the two `all` roots (`probes/probe_scale.ml:36-60`);
- the timings are single-run wall clock results from a different recorded commit.

Those weaknesses prevent precise asymptotic fitting, but they do not explain why the idle cost scales with graph size. The code trace independently establishes that behavior.

#### Amended statement

> Every stabilization performs graph-wide registry/reachability work even when user-function recomputation is change-proportional. Bind planning and observer ordering can add repeated graph traversals on top.

#### Correction

**Invariant — quiescent stabilization:** At the observation boundary of one graph lane, when there are no dirty source/timer/custom nodes, no topology or demand transition, no registering/disposed observer transition, no pending callback delivery, and no pending cleanup, a stabilization shall perform O(1) scheduler work and shall not scan the live-node registry or observer-root graph.

**Event-driven requirement:** When a node crosses from clean to dirty, the system shall enqueue that node or its affected frontier exactly once until processed; recomputation shall be ordered so every dependency settles before its consumer.

**Demand requirement:** When an observer or dynamic edge changes demand, necessity shall be updated incrementally from 0→1 and 1→0 demand-reference transitions rather than reconstructed from all roots.

The original audit’s “no source var passed its cutoff ⇒ O(1)” invariant is too broad: timers, lifecycle changes, and failed pending deliveries can legitimately create work without a source-var change.

#### Sequencing and blast radius

Land F13’s deterministic work counters first. Then replace the scheduler and necessity model. This touches graph node state, dirty propagation, observer registration/disposal, bind/keyed edge changes, timer start/stop demand, stats, DOT metadata, and nearly every model test. Public signal types need not change.

---

### F2 — No Expert-class extension surface; keyed engine embedded in kernel behind an Obj seam

**Verdict: AMENDED. The embedding is confirmed; the `Obj` causal claim and proposed public-Expert correction are rejected. Downgrade from mandatory P1 correction to an architecture decision.**

#### Evidence

`incr_map` really is implemented as a separate library over `Incremental.Expert`: `generic_mapi'` creates nodes, makes them stale, adds/removes dependencies, and invalidates removed nodes (`incr_map/src/incr_map.ml:753-847`).

Eta’s keyed engine is indeed inside `eta_signal_kernel` (`lib/signal/kernel/eta_signal_kernel.ml:1976-2122`), and `eta_signal_map.Make` instantiates that kernel directly (`lib/signal_map/api/eta_signal_map_api.ml:40-42`). Therefore future node kinds with custom recompute and dynamic dependencies cannot currently be implemented as ordinary external libraries.

But the production sibling-package path is typed:

- `eta_signal_map_api.ml` builds typed `keyed_map_ops` and `keyed_diff_ops` records (`lib/signal_map/api/eta_signal_map_api.ml:48-76`).
- Those records are passed to `Signal.Extension.keyed_mapi` without `Obj` (`lib/signal_map/api/eta_signal_map_api.ml:48-76`).
- The `Obj.t` token surface is re-exported only inside `Keyed.Testing` (`lib/signal_map/api/eta_signal_map_api.ml:78-103`) and implemented by testing/introspection helpers in the kernel (`lib/signal/kernel/eta_signal_kernel.ml:3584-3684`).

Therefore the statement “the keyed library boundary itself requires `Obj`” is false. F7 is real, but it is a private testing-token defect, not the production engine protocol.

#### Amended statement

> Eta has a closed graph engine. `eta_signal_map` works only by instantiating a kernel that already contains the keyed node kind. This prevents independently linked custom node libraries, but the existing production keyed path is type-safe.

#### Recommendation

Reject a broad public `Expert` API for now. A public mutation API would expose the most difficult invariants—phase, cycle detection, dependency indexing, invalidation, demand, rollback, and callback ordering—before there is evidence that more than one external node-kind implementation needs it.

Choose one of these mutually exclusive directions:

1. **Closed engine:** keep keyed nodes in the kernel and amend the ADR to explicitly accept that consequence. Then reduce the private protocol and fix F7 independently.
2. **Narrow first-party SPI:** if a second real node-kind package appears, expose a sealed, typed, package-level custom-node protocol. It should not expose arbitrary graph mutation; it should let the engine own phase, scheduling, rollback, demand, and invalidation.

Do not publish Jane Street’s full `Expert` shape merely to make the architecture look similar.

#### Sequencing and blast radius

Resolve after N1/N2 and preferably alongside F1/N4, because a stable extension contract depends on the final scheduler and edge representation. A broad public API would have a very large permanent blast radius; a private typed SPI affects `eta_signal_kernel`, `eta_signal_map_api`, Dune package boundaries, and negative compile-fail tests.

---

### F3 — `eta_signal.mli` law-bearing prose is unregistered

**Verdict: AMENDED; the normative-prose half is confirmed, the registry violation is not independently decidable from this pack.**

#### Evidence

`eta_signal.mli` clearly contains executable behavioral law, including:

- observer initialization, cutoff, typed callback failures, and invalid-scope reads (`lib/signal/eta_signal.mli:320-372`);
- bind invalidation and rollback-visible purity (`lib/signal/eta_signal.mli:524-541`);
- transactional stabilization, pending-delivery retry, and coalescing (`lib/signal/eta_signal.mli:543-565`);
- timer clock/catch-up behavior (`lib/signal/eta_signal.mli:589-699`);
- stream drop and lifecycle behavior (`lib/signal/eta_signal.mli:702-765`).

However, `LAWS.md` and the test files are explicitly absent from the pack. The embedded audit’s census cannot be reproduced independently.

#### Amended requirement

**Repository-policy requirement:** Every normative span in `eta_signal.mli` shall have an exact registry entry naming either an executable test/property or dated debt. Existing tests should be registered rather than duplicated.

This should be accepted only after maintainers provide the relevant `LAWS.md` ranges and named tests. Until then, label F3 “unverified policy violation,” not a confirmed code defect.

#### Sequencing and blast radius

Documentation/registry only unless gaps require tests. Land after P0 fixes so new transactional laws and regression tests are registered in the same change.

---

### F4 — Observer update stream has no lifecycle events

**Verdict: AMENDED; the type difference is real, but the stated stream impact and the proposed `Unnecessary` event are wrong. Downgrade to P2/API-choice.**

#### Evidence

The public observer update type is only:

```ocaml
type 'a update =
  | Initialized of 'a
  | Changed of { old_value : 'a; new_value : 'a }
```

(`lib/signal/eta_signal.mli:167-172`). Jane Street node handlers have `Necessary`, `Changed`, `Invalidated`, and `Unnecessary` (`incremental/src/on_update_handler.ml:14-23`).

But Eta stream consumers already distinguish terminal lifecycle outcomes:

- `Finish_disposed` maps to clean `Queue.close`;
- `Finish_invalid_scope` maps to `Queue.close_with_error queue `Invalid_scope`;

(`lib/signal/kernel/eta_signal_kernel.ml:66-90`). `Stream.observe` wires that finish hook into observer creation (`lib/signal/kernel/eta_signal_kernel.ml:196-212`). So the audit’s claim that stream consumers cannot distinguish invalidation from disposal is refuted.

Moreover, Jane Street’s `Unnecessary` is not terminal: a node can later become necessary again. In Eta, a registering or active observer itself demands its root (`lib/signal/eta_signal_observer.ml:127-145`), so the observed root cannot become unnecessary while that observer remains active. Importing `Unnecessary` into this observer-specific update type would misstate Eta’s lifecycle.

#### Amended statement

> Direct `Observer.observe` callbacks do not receive a typed invalidation event; invalidation is visible through `Observer.read`, observer finish hooks inside the implementation, and stream close-with-error. There is no missing meaningful `Unnecessary` event for an active Eta observer.

#### Optional contract

Only add a public lifecycle surface if direct-callback users need it. Prefer separating values from lifecycle:

```ocaml
type observer_finish =
  | Disposed
  | Invalidated

val observe :
  ?equal:('a -> 'a -> bool) ->
  ?on_finish:(observer_finish -> (unit, observer_error) Eta.Effect.t) ->
  'a signal ->
  ('a update -> (unit, observer_error) Eta.Effect.t) ->
  ('a observer, graph_error) Eta.Effect.t
```

Do not encode disposal as an ordinary update delivered after disposal, and do not add `Unnecessary` unless Eta first exposes node-level handlers whose demand can independently drop and return.

#### Sequencing and blast radius

Independent of the scheduler, but public API and stream adapters would move. Existing callers must be updated directly; no compatibility shim.

---

### F5 — Support-layer over-abstraction

**Verdict: AMENDED, maintainability problem confirmed; proposed universal rule rejected.**

#### Evidence

The graph interface itself says there is “currently exactly one adapter” and that the callback records are implementation protocol rather than a reusable extension surface (`lib/signal/eta_signal_graph.mli:1-13`). The support layer contains many multi-parameter plan/port records and one-constructor wrappers that forward closures between the kernel and a single implementation.

That indirection materially complicates review of phase ordering. N2 is a good example: keyed invalidation is assembled in the kernel, staged-bind state is owned by `eta_signal_graph.State`, switch lifecycle is delegated to `eta_signal_bind`, and commit orchestration is in `eta_signal_stabilization_pass`. Each local module looks reasonable while the cross-module order is wrong.

But “every abstraction needs two instantiations” and “never use a record of closures” are poor invariants. Single-use abstractions can be valuable when they make illegal phase transitions unrepresentable; `eta_signal_transaction` and `eta_signal_stabilization` are examples worth retaining after their exception-safety defects are fixed.

#### Amended correction

**Review invariant:** A support abstraction shall survive only if it owns at least one named invariant that its caller cannot express as clearly with a direct function or private concrete type.

After scheduler and transaction fixes:

- inline one-constructor wrappers whose only purpose is renaming one call;
- collapse single-caller “port” records where fields are always assembled and consumed together;
- retain small phase-typed state machines and pure timer-policy logic;
- move subsystem modules rather than merging everything into one kernel file.

#### Sequencing and blast radius

Do this last among architectural changes. Simplifying before F1/N2 may create churn twice and erase useful phase boundaries during correctness work.

---

### F6 — Dead functors in `eta_signal_graph_algorithms`

**Verdict: AMENDED, conditionally confirmed.**

#### Evidence

Within the packed production files, `Make_reachable`, `Make_order`, `Make_versions`, `Make_dirty`, and `Make_compute` appear only in their definitions/interfaces and in the audit text. The live graph implementation duplicates their operations directly. `Make_edges` is the one production instantiation.

Because tests are missing, the audit’s repository-wide grep cannot be reproduced. A test-only instantiation would not justify retaining duplicate production abstractions, but it changes the mechanical deletion plan.

#### Correction

**Event-driven requirement:** When whole-repository usage search confirms no production consumer, delete the five functors and matching `.mli` entries in one change. If tests instantiate them, redirect tests to the live engine behavior or move a truly reusable pure algorithm into a small module with one canonical implementation.

#### Sequencing and blast radius

Low semantic risk, but perform after N1/N2 and before broad F5 cleanup. Affects support modules and direct unit tests only.

---

### F7 — `Obj` casts on the extension/testing seam

**Verdict: CONFIRMED. Priority P2, independent of F2.**

#### Evidence

`Extension.keyed_entry_identity` casts an untyped caller key with `Obj.magic`; it returns one monomorphic `token = Obj.t` for keys, scopes, sources, data signals, and child signals; `keyed_scope_valid` then interprets any such token as a scope using `Obj.obj` (`lib/signal/kernel/eta_signal_kernel.ml:3584-3656`). A wrong token is not a typed mismatch or loud validation error; it is representation confusion.

The surface is private/testing-oriented, which limits exposure, but it still violates the project’s stated “fail loudly” discipline and makes tests capable of invoking undefined behavior.

#### Contract correction

```ocaml
type keyed_entry_identity
type scope_token

type keyed_event =
  | Detached of scope_token
  | Invalidated of scope_token
  | Attached of scope_token

val keyed_entry_identity :
  'output signal -> key -> keyed_entry_identity option

val keyed_scope_token : keyed_entry_identity -> scope_token
val keyed_scope_valid : scope_token -> bool
```

If tests need identity checks for source/data/child signals, give each an opaque distinct token type or typed accessor. Do not use one universal token.

#### Sequencing and blast radius

Can land immediately. Changes private testing signatures and fixtures; production `Keyed.mapi` remains unchanged.

---

### F8 — Collection-fold family missing

**Verdict: CONFIRMED, correction amended. Priority P2.**

#### Evidence

`All` recursively computes every child and `Static_eval.all` materializes a full list whenever any child is considered changed (`lib/signal/kernel/eta_signal_kernel.ml:1963-1970`; `lib/signal/eta_signal_graph_algorithms.ml:489-524`). There is no associative tree reduction or update-aware fold family in the public interface.

This is a real capability gap for large fan-in aggregations, but the audit’s “O(1) amortized n-ary fold” requirement needs an algebraic contract. An arbitrary fold cannot be updated in O(1) without an inverse, replacement delta, or mutable accumulator law.

#### Contract options

Balanced, associative reduction:

```ocaml
val reduce_balanced :
  equal:('a -> 'a -> bool) ->
  combine:('a -> 'a -> 'a) ->
  'a signal array ->
  'a signal option
```

Required law: `combine` is associative at the library’s observation boundary. One child change performs O(log n) recomputations.

Update-aware unordered fold:

```ocaml
type ('input, 'acc) fold_delta = {
  add : 'acc -> 'input -> 'acc;
  remove : 'acc -> 'input -> 'acc;
  replace : 'acc -> old:'input -> new_:'input -> 'acc;
}
```

Only this stronger contract can promise O(1) amortized accumulator work per changed child.

#### Sequencing and blast radius

Implement after F1 and N4 so folds are not built on a scheduler/edge representation known to be graph-wide and quadratic. Public API, tests, complexity gates, and possibly a new node kind are affected.

---

### F9 — Small-surface parity gaps

**Verdict: REFUTED as one finding and as one correction batch.**

The inventory contains many true absences, but it combines unrelated categories:

- trivial aliases/compositions: `join`, an infix spelling, some `if_` forms;
- scheduler-sensitive convenience nodes: dedicated `if_`, `bind2..4`, `freeze`;
- introspection policy: `is_valid`, `node_value`, node-level `on_update`;
- major optional subsystems: memoization, virtual step functions, snapshots;
- F12’s dynamic cutoff decision.

Adding every Jane Street name or recording a negative compile test for every omission is not a coherent product requirement. A smaller correct API is preferable to an approximate clone.

One listed “gap” is especially misleading: Eta’s `Var.value` already returns the most recently set source value, including a value set since the last stabilization (`lib/signal/eta_signal.mli:292-298`). That covers the core semantics of Jane Street’s `Var.latest_value` even though the name differs.

#### Correction

Reject F9 as a ranked defect. Open separate RFCs driven by concrete workloads. Cheap aliases may be accepted when they improve readability without new semantics; major subsystems require their own contracts and performance models. Keep dynamic cutoff work under F12.

---

### F10 — Two-graphs footgun between `Eta_signal.Make` and `Eta_signal_map.Make`

**Verdict: CONFIRMED. Priority P2.**

#### Evidence

`Eta_signal_map.Make` creates a fresh `Eta_signal_kernel.Make` instance and includes it (`lib/signal_map/api/eta_signal_map_api.ml:40-42`). Therefore its signal type belongs to a different generative graph from a separately applied `Eta_signal.Make`.

The public `eta_signal_map.mli` begins with the map API and functor signature but does not warn that the outer functor must be the application’s graph functor (`lib/signal_map/eta_signal_map.mli:1-20`, `:118-126`). The type error is safe, but discovery is poor.

#### Correction

**Ubiquitous requirement:** The module-level documentation shall state that `Eta_signal_map.Make(E)()` creates an independent graph and subsumes `Eta_signal.Make(E)()`. Applications needing keyed signals shall apply the map functor as their sole graph functor and use the included core signal API.

No shim or conversion should be provided.

#### Sequencing and blast radius

Documentation-only and immediate. A later F2 architecture decision could remove the issue, but the warning is needed under the current design.

---

### F11 — No rescope option for bind branches

**Verdict: AMENDED and downgraded. The absence is true; the parity/priority argument is weak.**

#### Evidence

Eta always detaches the old inner, invalidates the old scope, and attaches the new inner (`lib/signal/eta_signal_bind.ml:356-368`). There is no rescope mode.

However, the packed Incremental configuration explicitly says `bind_lhs_change_should_invalidate_rhs = false` is a compatibility hack and that the default is `true` (`incremental/src/config_intf.ml:1-10`; `incremental/src/config.ml:4-6`). Thus ordinary Jane Street behavior also invalidates the old RHS. Eta is missing a nondefault compatibility/optimization mode, not failing baseline parity.

The semantic table also points this delta to F13; it should point to F11.

#### Recommendation

Reject the proposed near-term correction. Rescoping interacts with scope ownership, captured ancestor nodes, keyed children, timers, observer invalidation, rollback, and N2. Require a benchmarked branch-flapping workload and a separate semantics RFC before adding it.

#### Sequencing and blast radius

After N1/N2, F1, and an extension/scope decision. Potentially large public configuration and lifecycle-test impact.

---

### F12 — Cutoffs are static and structurally poor

**Verdict: CONFIRMED, correction split into two phases. Priority P2.**

#### Evidence

Eta stores a fixed equality function per node and exposes only `?equal`. Jane Street’s cutoff type distinguishes `Always`, `Never`, physical equality, compare, equality, and an arbitrary labeled function (`incremental/src/cutoff.ml:4-13`, `:30-37`). It also supports runtime replacement.

A named cutoff ADT improves semantics and diagnostics even without mutation. Runtime mutation is more delicate because changing a cutoff affects whether the node must be scheduled immediately.

#### Phase 1 contract

```ocaml
module Cutoff : sig
  type 'a t

  val always : 'a t
  (** Always suppress publication. *)

  val never : 'a t
  (** Never suppress publication. *)

  val phys_equal : 'a t
  val of_equal : ('a -> 'a -> bool) -> 'a t
  val of_compare : ('a -> 'a -> int) -> 'a t
end
```

Constructors should accept `?cutoff` rather than raw `?equal`; delete the old path and update all callers under the repository’s no-shim rule.

#### Phase 2 requirement

If runtime mutation is justified:

**Unwanted-behavior requirement:** If `set_cutoff` is called during the pure stabilization phase, the operation shall fail through a documented typed graph error before mutation.

The RFC must decide whether changing a cutoff merely affects future candidate comparisons or also marks the node dirty for immediate reevaluation. Without that decision, `set_cutoff` is underspecified.

#### Sequencing and blast radius

Named cutoffs can land independently. Runtime mutation should follow F1 because it must integrate with dirty scheduling. Public constructors and all call sites change.

---

### F13 — Missing scale gate for the core engine

**Verdict: CONFIRMED. Priority P2, but it is a prerequisite for F1.**

#### Evidence

The existing core benchmark contains a small static diamond and one dynamic bind workload, each repeated 10k times and compared to mutable refs (`lib/signal/bench/bench_signal.ml:25-105`). It does not bound graph work, fan-in, observer count, quiescent stabilization, bind fixpoint passes, or timer-demand scans.

The raw scale probe is not deterministic enough to be a gate and targets a different recorded revision.

#### Correction

Add internal counters or a test-only trace for:

- nodes reached by compute;
- dependency edges checked;
- weak registry cells scanned;
- observer roots scanned;
- comparator dependency-DFS visits;
- bind-fixpoint passes and bind candidates scanned;
- necessity traversal visits;
- timer-registry and timer-reachability visits.

Gate these scenarios at 1k/10k/100k nodes:

1. quiescent stabilization;
2. one source change affecting one narrow branch;
3. one source change affecting half the graph;
4. nested bind switch;
5. keyed child-only change;
6. wide `all` construction and invalidation.

Use deterministic operation counts as pass/fail. Wall time may be emitted as a non-gating artifact.

#### Sequencing and blast radius

Land before F1/N4. Mostly test/bench and private instrumentation; avoid permanently widening public `stats` unless users need the counters.

---

### F14 — Micro-duplications and placement

**Verdict: AMENDED.**

Extracting `Stream_bridge` from the top of the kernel is sensible: it is a coherent subsystem with queue publication, drop acknowledgement, lifecycle close, and metrics (`lib/signal/kernel/eta_signal_kernel.ml:1-214`). This improves ownership and reviewability.

Do not centralize every arithmetic helper solely because names repeat. Timer-deadline saturation, diagnostic-counter saturation, and identifier overflow have different laws and error boundaries. A single generic helper can obscure those distinctions—the transaction-ID defect N1 is exactly why counter policy should be explicit.

#### Correction

- Move `Stream_bridge` to a private `eta_signal_stream_bridge.{ml,mli}`.
- Deduplicate only helpers with identical semantics, name, overflow policy, and observation boundary.
- Keep checked identifier increment, saturating diagnostics, and capped time arithmetic separate and documented.

#### Sequencing and blast radius

Private refactor after correctness and scheduler changes. Dune module list and private tests move; no public behavior changes.

---

## 3. New findings

### N1 — P0 — Transaction-ID overflow wedges the stabilization phase

#### Location

- `lib/signal/eta_signal_stabilization.ml:107-117`
- `lib/signal/eta_signal_transaction.ml:41-71`
- `lib/signal/eta_signal_stabilization_pass.ml:274-294`

#### Evidence and counterexample trace

`Eta_signal_stabilization.begin_pure` performs these writes in order:

1. `t.state <- Pure`;
2. `t.pure_transaction_status <- Some Pure_transaction_active`;
3. `t.transaction <- Some (Eta_signal_transaction.begin_pure ())`.

The transaction constructor then calls a module-global `next_transaction_id`; at `max_int` it raises `Invalid_argument` (`lib/signal/eta_signal_transaction.ml:57-68`). The call to `begin_pure` is evaluated before the `try` block in `Eta_signal_stabilization_pass.run` (`lib/signal/eta_signal_stabilization_pass.ml:274-294`). Therefore the exception escapes without rollback after the phase has already changed.

Afterward:

- `state = Pure`;
- `pure_transaction_status = active`;
- `transaction = None`.

Every later stabilization returns `` `Reentrant_stabilization``. There is no public recovery operation. This also contradicts the public statement that internal stabilization/counter overflow fails before partial publication and does not wrap (`lib/signal/eta_signal.mli:552-555`).

The path is astronomically remote in production, but it is a genuine escaped overflow path and a permanent state-machine corruption. It is also straightforward to hit with the project’s existing style of fault-injection harness.

#### Impact

One graph is permanently unusable; the intended typed error channel is bypassed; the internal phase invariant is broken.

#### Correction

**Invariant — phase entry atomicity:** At every observation boundary, `state = Pure` implies a live transaction object and `pure_transaction_status = active`. No operation capable of raising may occur between establishing those fields.

**Unwanted-behavior requirement:** If transaction-token allocation cannot proceed, stabilization shall fail with `` `Counter_overflow "transaction id"`` while the graph remains `Idle`.

Prefer removing the global integer entirely. A fresh physical token owned by the graph/transaction is enough to distinguish pending cells:

```ocaml
type id = Id of unit ref
```

If an integer is retained, allocate/check it before mutating the phase and make it graph-local. Module-global refs are also unnecessarily raced by independent graphs running on different OCaml domains.

**Exception-safety requirement:** `begin_pure` shall either return a valid pure token with a live transaction or leave the state byte-for-byte equivalent to its prior `Idle` state.

#### Tests

- force the next transaction ID to overflow;
- assert a typed `Counter_overflow` result;
- assert `stabilize` can be called again successfully;
- run two independent graphs on separate domains if an integer/global allocator remains.

#### Sequencing and blast radius

First fix. Changes private transaction/stabilization token representation and overflow harness. No public success types need change; the typed `graph_error` taxonomy may gain a named counter path already representable by `Counter_overflow`.

---

### N2 — P0 — Keyed removal can commit a staged nested bind after invalidating its owner

#### Location

- bind planning: `lib/signal/kernel/eta_signal_kernel.ml:2407-2455`
- keyed removal planning: `lib/signal/kernel/eta_signal_kernel.ml:2074-2091`
- keyed invalidation/commit: `lib/signal/kernel/eta_signal_kernel.ml:1499-1698`
- bind commit: `lib/signal/eta_signal_bind.ml:356-368`
- transaction commit order: `lib/signal/eta_signal_graph.ml:203-227`

#### Concrete public graph

A keyed child builder may validly create a bind in that child scope:

```ocaml
let left  = S.const 1
let right = S.const 2
let choose = S.Var.create true

let keyed =
  Keyed.mapi input ~f:(fun ~key:_ ~data:_ ->
    S.bind (S.Var.watch choose) (fun b -> if b then left else right))
```

Observe `keyed`, stabilize once with a key present, then in one later cycle:

1. set `choose` so the nested bind switches from `left` to `right`;
2. set the keyed input so that the same key is removed;
3. stabilize.

#### Static trace

1. `plan_staged_bind_switches` runs before ordinary observer event collection. It traverses the **current** graph from active observer roots, finds the nested bind in the still-committed keyed child, computes it, creates a new bind scope, and stages its switch (`kernel:2407-2455`).
2. Computing the keyed owner later observes the input removal and records the child in `keyed_plan_removals` without computing that child (`kernel:2074-2091`).
3. `extend_keyed_invalidations` adds the removed child scope to the invalidation view (`kernel:1499-1515`). This view is used to skip doomed signal-snapshot commits and timer preflight, but it is **not** used to discard or partition `State.staged_binds`.
4. `preflight_commit_staging` calls `commit_keyed_plans` before the staged-cell transaction commits (`kernel:1670-1698`). `commit_keyed_removals` detaches the child edge and invalidates the child scope (`kernel:1555-1573`). Invalidation of the nested bind sees only its **current** bind snapshot, so it invalidates the old branch scope; the newly staged branch scope is not current yet.
5. `State.commit_staging` then iterates every staged bind before committing the transaction (`lib/signal/eta_signal_graph.ml:203-214`). There is no validity/invalidation predicate in that list.
6. `commit_switch` detaches the old inner, invalidates the old scope, and attaches the staged new inner to the already-invalid bind owner (`lib/signal/eta_signal_bind.ml:356-368`).
7. Signal-snapshot preparation discards the invalid node’s ordinary value snapshot, but the separate bind snapshot cell is still committed by the transaction. The invalid bind now points at the staged new inner/scope, and the new inner’s `dependents` list contains an invalid owner.

A particularly clear retained-topology case is when `left` and `right` are top-scope signals: the newly attached top-scope signal strongly retains the invalid bind through its `dependents` list. The edge is not removed by later dirty propagation because invalid nodes are skipped, so it is a persistent invalid edge and a retained invalid node visible to all-node diagnostics.

#### Impact

- successful stabilization can leave an invalid node attached as a dependent of a valid signal;
- dynamic-scope invalidation is not closed under staged bind state;
- invalid nodes and empty/new scopes can be retained;
- later topology algorithms operate on lists containing invalid parents;
- the public keyed transaction law—failure/success leaves committed identities and no pending transaction work—does not describe this hybrid state.

This is a correctness defect even when every user callback is pure and total; no exception or timer construction inside a bind is required.

#### Correction

**Invariant — invalidation closure:** Before any topology mutation commits, the engine shall compute a single fixed invalidation frontier containing all nodes/scopes invalidated by staged bind switches, keyed removals, and future extension plans. No staged operation owned by that frontier may subsequently commit.

**Event-driven requirement:** When a staged bind owner enters the invalidation frontier, the engine shall discard its staged bind snapshot and invalidate its provisional new scope during rollback/discard processing, not execute `commit_switch`.

**Commit invariant:** Every staged bind passed to `commit_switch` shall have a valid owner that is absent from the fixed invalidation frontier. This must be checked before any keyed/bind topology mutation.

A minimal internal plan shape would make the decision explicit:

```ocaml
type staged_bind_decision =
  | Commit_bind of packed_bind
  | Discard_bind of packed_bind
```

The commit phase consumes only `Commit_bind`; the discard phase invalidates provisional scopes and clears pending bind cells before the transaction commit.

Also make preflight semantically honest: it may validate and construct an immutable commit plan, but it must not detach edges or invalidate scopes. All non-failing topology actions should execute from that frozen plan in one commit phase.

#### Tests

- keyed key removal + nested bind switch in the same stabilization;
- nested bind switches to a top-scope signal; assert no invalid dependent edge remains;
- nested bind creates child-scope nodes; assert provisional new scope is invalidated/discarded;
- repeat add/remove/switch thousands of times and assert bounded `total_node_count`/dead-node behavior;
- run the same scenario with an observer callback failure after snapshot commit to ensure topology remains coherent.

#### Sequencing and blast radius

Second fix, before scheduler redesign. Touches keyed preflight/commit, staged-bind collection, invalidation views, transaction discard support, scope cleanup, DOT/stats tests, and signal-map model tests. Public types need not change.

---

### N3 — P1 — Observer graph-order comparator is not a total order

#### Location

- `lib/signal/eta_signal_graph.ml:808-825`
- `lib/signal/kernel/eta_signal_kernel.ml:2399-2405`
- `lib/signal/eta_signal_observer.ml:842-846`

#### Evidence

The comparator is:

1. equal ID → 0;
2. left depends on right → left after right;
3. right depends on left → left before right;
4. otherwise order by signal ID.

Dependency reachability plus unrelated-ID fallback is not transitive on a dynamic graph.

Construct three observed signals:

- `A`, an older bind owner;
- `C`, an unrelated signal created after `A`;
- `B`, a later-created RHS signal selected by `A`.

Choose IDs `A < C < B`, with `A` depending on `B`.

Then:

- `compare A B > 0` because `A` depends on `B`;
- `compare B C > 0` by ID;
- `compare A C < 0` by ID.

This creates a comparison cycle (`A < C < B < A`). `List.sort` requires a total order. The output may therefore violate the intended dependency-before-parent order and is not a stable semantic contract across implementations or input arrangements.

The audit’s S9 verdict “Eta stronger” is not established.

#### Impact

Callback order can be inconsistent precisely on dynamic-bind graphs where graph ordering was intended to add value. Sorting also performs repeated DFS work, contributing to F1.

#### Correction

Make a product decision:

- If callback order is **not public law**, sort only by observer ID and document that callbacks see a committed glitch-free snapshot but have no dependency order.
- If dependency order **is public law**, compute one topological order for the active observer roots per delivery plan (Kahn or DFS finishing order), with observer ID as the tie-break among simultaneously ready nodes. Do not call reachability DFS from a pairwise comparator.

**Invariant:** The callback order relation shall be a deterministic total order. If topological ordering is promised, every observed dependency precedes every observed transitive consumer.

#### Tests

Use the exact `A`, `B`, `C` dynamic-bind construction above; enumerate observer registration permutations and assert one stable order.

#### Sequencing and blast radius

Decide before F1’s scheduler rewrite because the scheduler may already maintain topological metadata. Observable callback ordering, docs, and model traces may change.

---

### N4 — P1 — Wide fan-in edge operations are quadratic

#### Location

- `lib/signal/eta_signal_graph_algorithms.ml:22-47`
- `lib/signal/eta_signal_graph.ml:1719-1737`
- `lib/signal/kernel/eta_signal_kernel.ml:1963-1970`

#### Evidence

`attach_dependency` checks both adjacency lists using `List.exists` before consing; `detach_dependency` rebuilds lists with `List.filter`. `Graph.create_live_node` loops over all dependencies and calls attachment once per child. Building a node with `n` dependencies therefore scans a parent dependency list of lengths 0…n−1: O(n²). Teardown of a wide parent similarly repeats list filters.

`all` is the public direct way to create such a wide node, so this is not merely an adversarial Expert graph.

The audit discusses this in §5.1 but omits it from F1–F14. It is independent of the graph-wide stabilization problem: even a perfect dirty scheduler would still construct/tear down wide nodes quadratically.

#### Impact

Large dashboards, table aggregations, and generated fan-in graphs can spend disproportionate time and allocation in graph construction/invalidation before stabilization economics are considered.

#### Correction

**Complexity invariant:** Creating or invalidating a static node with `n` distinct dependencies shall require O(n) adjacency work.

Possible representation split:

- immutable array/small-vector for static child dependencies;
- indexed parent slots or hash/index map for dynamic edge removal;
- a small optimized representation for 0/1/2 edges, widening only when necessary.

Do not copy Jane Street’s intrusive layout blindly, but make edge identity and removal O(1) or amortized O(1) where dynamic rewiring is required.

#### Tests

Deterministic operation-count gate for `all` at 1k/10k/100k children and for invalidating a scope containing one wide parent.

#### Sequencing and blast radius

Design with F1 because scheduler and edge representation constrain each other. Touches node records, bind/keyed rewiring, DOT, invalidation, and construction tests.

---

### N5 — P2 — Pre-commit and post-commit exceptions share one rollback path

#### Location

- `lib/signal/eta_signal_stabilization_pass.ml:294-333`
- `lib/signal/eta_signal_graph.ml:203-227`

#### Evidence

The `try` in `Stabilization_pass.run` covers:

- generation/staging/pending work;
- bind planning and event collection;
- transaction/topology commit;
- marking observer events pending;
- necessity update;
- timer-refresh-context clear;
- transition to `Delivering`.

Any exception in that whole region calls `rollback_current`. But once `State.commit_staging` has committed the staged-cell transaction and cleared the staging token, rollback is no longer legal. The current code relies on every operation after commit being non-raising; that is mostly true today, but the invariant is neither reflected in the types nor localized in the control flow.

N1 demonstrates the same general weakness at phase entry, and N2 shows how easy it is to misplace topology actions around “preflight.”

#### Impact

A future instrumentation hook, checked counter, extension callback, or invariant failure added after commit can turn a recoverable error into a second exception and leave the phase stuck. Reviewers cannot see the commit boundary from the exception structure.

#### Correction

Split the pass into explicit result-producing phases:

1. `plan_and_preflight : ... -> (commit_plan, error) result` — rollback legal;
2. `commit : commit_plan -> committed_payload` — no user callbacks, no fallible validation, no allocation-dependent planning;
3. immediately transition state to `Committed`/`Delivering`;
4. `post_commit` — failures preserve committed snapshot and use finalizer/suppressed diagnostics, never rollback.

**Invariant:** The rollback function is callable only while a live open transaction and active staging token both exist. Encode that with phase-specific tokens rather than a shared mutable option check.

#### Sequencing and blast radius

Fix alongside N1/N2. Private stabilization/graph APIs and fault-injection tests change; public semantics become more faithfully implemented.

---

## 4. Semantic-parity table challenges

| Row | Review verdict | Independent assessment |
|---|---|---|
| **S1 Glitch freedom** | Parity | **Retain.** Generation caching and dependency-first pull evaluation support it; no counterexample found. |
| **S2 Work per stabilization** | Delta/F1 | **Amend.** Multiple registry/reachability scans, bind fixpoint scans, and pairwise DFS sorting make the gap larger than one O(necessary) traversal. |
| **S3 User recomputation** | Parity | **Retain**, within the static-node/version-vector boundary. |
| **S4 Bind switch condition** | Parity | **Retain.** |
| **S5 Old bind branch disposal** | Delta/F13 | **Amend.** Finding reference should be F11. Default Incremental also invalidates; rescope is nondefault compatibility behavior. |
| **S6 Bind cascade convergence** | Parity | **Retain for bind-only cascades.** It does not cover N2’s keyed-removal invalidation of an already staged nested bind. |
| **S7 Failed bind switch** | Parity | **Retain** for selector/validation failure before commit. |
| **S8 Var set during stabilization** | Parity | **Retain.** |
| **S9 Observer ordering** | Eta stronger | **Refute.** The comparator is non-total (N3). |
| **S10 Delivery coalescing** | Eta richer | **Retain**, subject to the documented at-least-once behavior around callback failure/interruption. |
| **S11 Lifecycle events** | Delta/F4 | **Amend.** Direct callbacks lack invalidation events, but streams distinguish clean disposal from invalid scope; `Unnecessary` is not meaningful for an active observer. |
| **S12 Rollback** | Eta stronger | **Refute as universal.** N2 leaves hybrid topology on a successful mixed keyed/bind transaction; N1 corrupts phase on overflow before a transaction exists. |
| **S13 Deep graphs** | Eta stronger | **Narrow.** Probe A establishes one packed shape/runtime, apparently with a small observer set. It does not cover multi-observer pairwise dependency DFS or the exact packed revision. |
| **S14 Counter overflow** | Eta stronger | **Refute as universal.** Transaction-ID overflow escapes the typed channel and wedges state (N1). |
| **S15 Dynamic cutoffs** | Delta/F12 | **Retain.** |
| **S16 Cross-domain safety** | Different/feature | **Retain**, but replace module-global transaction/state ID refs as part of N1 hardening. |
| **S17 Cycle detection** | Parity; Incremental structurally impossible | **Amend wording.** Incremental explicitly documents that `bind`/Expert edges can create cycles and that height adjustment detects them (`incremental/src/incremental_intf.ml:210-211`, `:296-306`). The parity conclusion is reasonable; the explanation is wrong. |

---

## 5. Ranked correction plan

### 1. Fix N1 — atomic phase entry and transaction identity

**Requirement:** Transaction allocation shall occur before phase mutation, or phase mutation shall be protected by a guaranteed rollback that cannot itself fail. Overflow shall be typed and leave the graph idle.

**Dependencies:** none.
**Blast radius:** private transaction/stabilization modules, overflow harness.
**Gate:** forced overflow followed by successful retry.

### 2. Fix N2 — one invalidation frontier and staged-operation partition

**Requirement:** Bind switches, keyed removals, and extension invalidations shall be merged into one frozen frontier before commit. Staged binds whose owners are in that frontier shall be discarded, never committed.

**Dependencies:** N1’s reliable phase/rollback boundary.
**Blast radius:** kernel keyed/bind planning, graph commit plans, scope invalidation, signal-map tests.
**Gate:** keyed removal + nested bind switch regression and bounded retained-node count.

### 3. Fix N5 — split plan/preflight, commit, and post-commit exception regions

**Requirement:** Rollback shall be type-callable only before transaction commit. Post-commit failures shall never invoke rollback.

**Dependencies:** N1/N2 design.
**Blast radius:** private stabilization orchestration and fault injection.

### 4. Land F13 — deterministic core work instrumentation

**Requirement:** The repository shall gate operation counts for quiescent, narrow-change, bind, keyed, multi-observer, and wide-fan-in workloads.

**Dependencies:** may begin in parallel with P0 fixes if instrumentation is non-invasive.
**Blast radius:** benches/tests/private counters.

### 5. Decide and fix N3 callback ordering

**Requirement:** Observer delivery order shall be a deterministic total order. If dependency order is promised, compute one topological order, not pairwise reachability comparisons.

**Dependencies:** product decision; coordinate with F1.
**Blast radius:** observable callback traces and docs.

### 6. Redesign F1 scheduling and incremental demand

**Requirement:** Quiescent stabilization O(1); dirty/downstream proportional scheduling; incremental necessity and timer demand.

**Dependencies:** F13; preferably N3 decision.
**Blast radius:** central graph engine, timers, bind/keyed topology, stats, model tests.

### 7. Redesign N4 edge storage

**Requirement:** O(n) wide-node construction/invalidation and efficient dynamic edge removal.

**Dependencies:** co-design with F1.
**Blast radius:** node representation and all topology operations.

### 8. Fix F7 typed testing tokens

**Requirement:** No `Obj.magic`/`Obj.obj` on any package/testing boundary; distinct opaque token types.

**Dependencies:** none.
**Blast radius:** private test API and fixtures.

### 9. Document F10 immediately

**Requirement:** `Eta_signal_map.Make` documented as the sole graph functor for keyed applications.

**Dependencies:** none.
**Blast radius:** docs only.

### 10. Settle F3 with the missing registry/tests

**Requirement:** Every normative span gets a registry row and executable test or dated debt.

**Dependencies:** maintainers provide omitted files; include new N1/N2 laws.
**Blast radius:** registry and tests.

### 11. Add F12 named cutoffs; defer mutation semantics

**Requirement:** Replace raw optional equality with a named cutoff ADT. Add `set_cutoff` only after its scheduling semantics are specified.

**Dependencies:** runtime mutation depends on F1.
**Blast radius:** public constructors and all callers.

### 12. Add F8 folds after scheduler/edge work

**Requirement:** Balanced O(log n) associative reduction and, only with explicit delta algebra, O(1)-amortized unordered accumulation.

**Dependencies:** F1/N4.
**Blast radius:** public API, node kinds, complexity tests.

### 13. Treat F4 as optional API work

**Requirement:** If demanded, expose a separate observer finish event. Do not add a misleading `Unnecessary` value update.

**Dependencies:** product need.
**Blast radius:** observer API and adapters.

### 14. Simplify F5/F6/F14 after architecture settles

**Requirement:** Remove dead functors, inline semantically empty wrappers, extract Stream_bridge, retain phase-typed state machines and pure policy modules.

**Dependencies:** after N1/N2/F1/N4 to avoid duplicate churn.
**Blast radius:** private modules, Dune, tests.

### Explicitly rejected/deferred corrections

- **F2:** do not publish a broad `Expert` API without a second real external node-kind consumer and a stable invariant set.
- **F9:** do not pursue API parity as one batch; split by use case.
- **F11:** do not add bind rescoping without a benchmarked workload and a full scope/lifecycle RFC.

---

## 6. Open questions for maintainers

1. Which revision is authoritative for this review: packed `4197be98` or probe/audit baseline `5694938a`? Please rerun deterministic work-count gates on the chosen revision.
2. Please provide `LAWS.md` around the cited census and the exact named signal/model/contract tests. That is required to settle F3 and the repository-wide half of F6.
3. Is dependency-ordered observer callback delivery intended public law? The current API prose appears to promise consistent snapshots, not topological callback order. This decision determines whether N3 should become a topological scheduler feature or be simplified to ID order.
4. Does an existing test combine a keyed child containing a bind, a global bind-source change, and removal of the same key in one stabilization? If so, provide it; the packed code trace in N2 predicts retained invalid topology that ordinary output assertions may miss.
5. Is the private `Keyed.Testing` token API intentionally usable by packages outside the repository? If not, can it be replaced by typed assertions local to the test executable rather than a CMI-visible generic token surface?
6. Does ADR 0004 still categorically reject any first-party custom-node SPI, or only a broad application-facing Expert API? The ADR itself is not packed, and that distinction materially changes F2.
7. For future cutoff mutation, should changing the cutoff re-evaluate the current cached value immediately or affect only future candidates? This must be decided before exposing `set_cutoff`.

---

## 7. Binding recommendation

Do **not** begin by adding API parity or publishing `Expert`.

First repair the transaction/topology boundary (N1, N2, N5), instrument graph work (F13), then redesign scheduling and edge storage (F1, N3, N4). Those changes determine the stable internal laws on which extension APIs, folds, dynamic cutoffs, and cleanup refactors must depend.

The current library is semantically ambitious and often carefully engineered, but its correctness argument is distributed across too many phase adapters. The immediate goal should be one explicit immutable commit plan with a closed invalidation frontier, an atomic phase machine, and measurable dirty-driven work. Everything else is downstream.
