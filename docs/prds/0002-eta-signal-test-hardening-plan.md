# Eta Signal Test Hardening Plan

Status: living plan

This plan tracks agreed test-hardening work for `eta_signal` after the initial
PRD and implementation. It is intentionally focused on executable coverage:
tests that increase confidence in graph correctness, lifecycle behavior,
failure propagation, and portability.

Update rule: while grilling continues, append or revise this file after every
few accepted decisions.

## Test Oracle Policy

- Use Jane Street Incremental as the primary behavioral oracle because Eta
  Signal intentionally follows explicit stabilization, demand via observers,
  dynamic bind scopes, and non-automatic propagation.
- Use SolidJS, Reactively, and Alien Signals only for model-independent stress
  cases: diamond deduplication, dependency switching, disposal cleanup,
  batching, cycle detection, stale-read prevention, and subscription cleanup.
- Do not port automatic scheduling, lazy read recomputation, owner trees,
  microtask batching, or global hidden graph behavior.
- Port Incremental tests through Eta public contracts, not exact internals.
  Prefer observer values/events, `stats`, `to_dot`, typed failures, defects,
  and recompute counters.
- Do not literally port Incremental tests for `Expert`, exact node heights,
  timing-wheel internals, analyzer fields, or permanent poisoned-state
  behavior.

## Accepted Test Backlog

| ID | Area | Accepted test work | Priority | Source |
| --- | --- | --- | --- | --- |
| T01 | Dynamic scope | Captured bind RHS nodes cannot be observed or made necessary after their dynamic scope is invalidated; expect typed `Invalid_scope`. | High | Incremental invalid bind RHS/scope tests |
| T02 | Dynamic cycles | Add multi-node dynamic cycle tests using signal-valued variables plus `bind signal (fun x -> x)`: valid one-way rewires, valid reverse-order rewires, and both-directions cycle producing typed `Cycle` with previous snapshot preserved. | High | Incremental join/bind cycle tests |
| T03 | Observer liveness | Observe a var after stabilization, observe a set var after stabilization, and verify disposal plus stabilization removes necessary graph from `stats`/`to_dot`. | Medium-high | Incremental observer/skeleton tests |
| T04 | Observer/effect phase mutation | During an observer callback, set the same source multiple times. `Var.value` sees the latest pending value, current observer reads still see the snapshot, and the next stabilization publishes the final value. | Medium | Incremental set-during-stabilization tests adapted to Eta observer phase |
| T05 | Physical cutoff pitfall | Mutate the same heap block in place, set the source to the same physical object, and verify default physical equality suppresses propagation while direct source value exposes the mutated object. | Medium | Incremental cutoff pitfalls |
| T06 | Map matrix | Add full public `map` through `map9` behavior matrix: constants initialize, watched vars initialize, input changes update, repeated pre-stabilization sets publish final values, callback defects preserve/retry, custom equality suppresses downstream propagation. | Medium | Incremental map arity tests |
| T07 | Map graph invariants | For `map2` and `map9`, test repeated same child does not duplicate source recomputation; child cutoff suppresses `mapN`; two children changed before one stabilization recompute once with final values. | Medium | Incremental map invariants |
| T08 | Dynamic list bind | Port dynamic dependency-set case: list-of-indices source selects watched vars from an array, sums them, detaches old inputs, ignores excluded input updates, and attaches new inputs after index changes. | High | Incremental Part 2 dynamic bind docs |
| T09 | Bind performance semantics | Compare equivalent `map3` sum and nested-bind sum. Both produce same values, while nested bind visibly recreates RHS scopes according to bind semantics and does not retain stale scopes. | Medium | Incremental bind pitfalls |
| T10 | Observer typed failure retry | Observer callback fails once with `Effect.fail`; `stabilize` returns `Observer_error`; snapshot publication is as documented; later stabilization after fixing the flag succeeds and publishes a new value. | Medium | Eta replacement for Incremental poisoned-state tests |
| T11 | Observer interruption retry | Interrupt an observer callback during stabilization; verify phase/lane cleanup, then later stabilization succeeds and publishes a new value. | Medium | Eta interruption semantics |
| T12 | Observer lifecycle in callbacks | Register a new observer inside an observer callback; it must not run in the current stabilization and initializes on the next one. Also test self-disposal during callback prevents future callbacks. | Medium | Eta observer/effect phase contract |
| T13 | Timer catch-up/coalescing | Large clock jumps for `Time.interval`, `Time.after`, `Time.deadline`, and `Time.now`: no past-reschedule loop, no hidden auto-stabilization, and documented catch-up or coalescing behavior is asserted. | High | Incremental clock tests adapted to Eta timers |
| T14 | Timer branch churn | Repeatedly toggle a timer branch through `bind`; sleeper count returns to zero while inactive, exactly one sleeper exists when active, and no duplicate daemons accumulate. | Medium-high | Dynamic scope plus timer demand |
| T15 | Stream subscription stress | Add stream bridge disposal/subscription stress: multiple bridges on one signal, one bridge disposed without affecting another, full bridge queues do not block later observers, full bridge queues do not mask observer failures, self-disposal during stream observer update is deterministic. | Medium | Solid/Reactively/Alien subscription cleanup adapted to Eta |
| T16 | Debug as analyzer | Strengthen `stats`/`to_dot` as the public replacement for Incremental analyzer/skeleton tests: before/after observation, after final disposal, bind branch changes, and repeated read-only calls. | Medium | Incremental analyzer/skeleton tests |
| T17 | Compile-negative boundaries | Add targeted negative tests: pure `map` cannot perform Eta mutation as a value, observer-read errors do not silently collapse into graph errors, repeated `Make(Same_error)()` instances are incompatible, and `Time` constructors are effectful. | Medium | Eta API boundary decisions |
| T18 | Randomized model tests | Add deterministic randomized/model tests for small graphs built from vars, `map`, `map2`, `all`, and simple `bind`; random operations compare Eta observer values against a from-scratch stabilization-boundary model and assert observer/disposal/read invariants. Keep fixed seeds in the normal suite; consider Crowbar/fuzz smoke later. | Medium-high | Model-based testing adapted to Eta semantics |
| T19 | js_of_ocaml subset | Add a mainline-only `eta_signal` JS suite covering basic observe/stabilize/read, bind branch switching and stale dependency detachment, typed failure/defect propagation, `Time.now`/`Time.interval` explicit stabilization with JS timers, stream bridge emission/close, and interruption cleanup where supported. | High | Backend portability |
| T20 | Test/benchmark split | Keep small deterministic correctness stress in regular `dune runtest`; put large dynamic-list, branch-churn, fanout, and manual-`Mutable_ref` comparison work in opt-in `bench_signal` benchmarks. | Medium | Gate performance policy |
| T21 | Fanout/fanin stress | Add wider fanout/fanin graph tests: one source through many children into `all`/sum, cutoff near root suppresses all children, partial observer disposal keeps shared necessary nodes, final disposal clears the graph. | Medium-high | FRP benchmark-style graph shapes |
| T22 | Observer graph ordering | Add deterministic observer ordering tests across upstream/downstream observers and independent branches, guarding against hash-table/list nondeterminism. | Medium | Subscriber ordering stress adapted to Eta |
| T23 | Snapshot consistency in callbacks | Multiple observers read each other during callbacks and all see the same published snapshot; source mutations during one callback affect only the next stabilization. | Medium | Glitch-freedom/snapshot consistency |
| T24 | Diamond glitch freedom | Add value-level diamond tests proving observers see only fully new upstream/downstream values, never mixed old/new intermediate values; include observers on both arms and downstream node. | High | Core FRP glitch-freedom invariant |
| T25 | Bind churn | Add rapid non-time bind switching across A/B/C branches over many stabilizations; inactive branches do not recompute/emit, reactivated branches use latest source once, and scope/demand stats move plausibly. | High | Dynamic dependency churn |
| T26 | Stream overflow progress | Fill a `Stream.observe ~capacity:1` bridge queue, verify stabilization and later observers still progress, dropped bridge updates do not hold the graph lane, and disposal still drains buffered updates before closing. | Medium-high | Eta progress plus stream bridge |
| T27 | Timer startup/shutdown race | If deterministic without test-only hooks, cover timer becoming necessary then losing demand around daemon startup so no sleeper/daemon leaks and re-observation starts exactly one timer. Otherwise keep as lower-priority stress. | Medium | Eta timer daemon lifecycle |
| T28 | Public docs | Update `.mli` docs for public semantic guarantees hardened by tests: explicit stabilization, observer handle role, physical equality, bind invalid scope, observer phase semantics, stream ownership/domain/overflow, and timer demand ownership. | Medium | Consumer-facing contract |
| T29 | Build-checked examples | Add tiny build-checked examples for explicit stabilization with derived state and for timer or stream bridge lifecycle/disposal. Use them as API smoke tests, not tutorials. | Low-medium | API usability |

## Explicit Non-Ports

- No positive `map10` tests; `map10` remains a compile-negative boundary.
- No `Expert` stepping tests.
- No exact Incremental height/max-height tests.
- No timing-wheel precision tests.
- No Incremental permanent-poisoning behavior tests.
- No JS automatic-scheduler or lazy-read recomputation parity tests.
- No GC/finalizer-dependent correctness tests for observer cleanup; explicit
  disposal is the portable contract.

## Open Grilling Areas

- None recorded yet.

## Audit Clarifications

- T15 "self-disposal during stream observer update" is not directly
  expressible as a callback on the internal stream bridge observer; the public
  contract exposes the returned observer handle instead. The public-contract
  test case disposes that returned observer from another observer callback in
  the same observer/effect phase after the bridge update is queued, then asserts
  that the queued update drains, the stream closes, and later stabilizations can
  proceed.
