# Public Signal interface and graph ownership

Type: grilling
Status: resolved
Blocked by: 17

## Question

Does the promoted execution model fit behind the current public Signal
interface, or does another interface create substantially more module depth?

Compare alternatives by caller knowledge, leverage, error modes, lifecycle
rules, performance characteristics, and testability. Do not preserve the
current interface through a compatibility adapter.

Decide the owner-domain and owner-fiber rules.
Decide whether map, bind, cutoff, and keyed builder functions can yield.
Compare separate public operations with fused, batch, and session operations.

Implement the selected interface directly in the production pre-alpha engine.
Run the complete behavior gate and each affected performance row.

## Answer

The public Signal interface is synchronous on one owner domain. The lane, the
per-operation fiber protocol, and the Eio dependency in the operation path are
deleted. No compatibility adapter exists.

Decisions, confirmed by the grilling record:

1. Hot-path operations are synchronous. `Var.set`, `stabilize`,
   `Observer.read`, `Observer.dispose`, `stats`, and `to_dot` return results
   directly. They are not Eta effects.
2. One owner domain per graph. Use from a foreign domain or from a worker
   callback raises `Invalid_argument`. This check is a deliberate fence. It can
   move toward no domain check later.
3. Builders are pure and synchronous. `const`, `map`, `bind`, `Var.create`,
   `Var.watch`, and cutoff combinators construct nodes directly. Construction
   outside a valid scope raises `Graph_error`.
4. The generative functor stays. Each `Make ()` instance owns one graph
   identity.
5. Observer callbacks are synchronous. They return
   `(unit, observer_error) result`. A typed failure settles the delivery and
   reports the error. A raised exception leaves the event pending; the next
   stabilization retries it.
6. Error channels split by phase. Construction failures raise `Graph_error`.
   Stabilization failures return typed errors.
7. Graph phases are explicit: `Idle`, `Planning`, `Delivering`. Sets during
   delivery stay pending until the next stabilization. Reentrant stabilization
   is a typed error.
8. `Var.update_effect` stays effectful. It keeps the per-variable lease.
9. Timer lifecycle is synchronous on the owner domain. Each timer binds to the
   runtime that created it. Timer use with a different runtime is a typed
   `Runtime_mismatch` at creation. One stabilization shares one clock snapshot
   per runtime.
10. `For_stream` is deleted. The stream bridge consumes synchronously with an
    auto-acknowledgement sink over a bounded queue. Offer and drop defects are
    buffered and reported at the next bridge operation.
11. `Observer.dispose` returns a result.

Implementation summary:

- The kernel factory is rewritten around `Execution = { owner_domain }` with a
  synchronous context fence. `selected_edges` runs delivery plans directly.
- Timers carry their own runtime record. The graph-global runtime is gone.
- The stream bridge, `eta_signal_map`, Crux, and the benchmark harnesses are
  migrated to the synchronous interface.
- `eta_signal_lane` and its test suite are deleted. They had no remaining
  consumer.
- Lane-only interruption and queueing tests are deleted. Their scenarios exist
  only under the lane. The surviving guarantees are structural or covered by
  rewritten tests.

Behavior-gate fixes found and made during implementation:

- Coalescing state advances on typed callback failure. Without this, the next
  event after a typed failure was lost.
- Construction-guard raises inside delivered callbacks convert to typed
  stabilization errors, matching the error-channel rule.
- Timers refresh from one clock snapshot per runtime per stabilization. The
  per-timer runtime migration had broken the single-snapshot contract.
- `scope_parents` and `scope_owners` are pruned on bind-switch retirement.
  They grew without bound. Dynamic switch cost fell from more than 100 µs to
  1.5 µs per operation.

Behavior gate, all through the Nix toolchain:

- `dune runtest --force`: green. 2440 Alcotest tests across 61 suites, plus the
  qcheck suites (including 37 keyed rollback properties at 1000 cases each).
- Negative compile fixtures: green.
- `dune build @install`: green.
- Shipped-package subset gate: green.

Performance rows, frozen harness, three nine-sample runs, one pinned CPU,
medians per operation. "Was" is the pinned pre-redesign finalist from the
evidence bundle. The acceptance-matrix gate is the frozen `1.20` wall-time
ratio and the layered allocation ceilings from issue 04.

| Workload | Wall (ns) | Words | Was (ns) | Was (words) | Wall ratio | Words ratio | Matrix gate |
|---|---:|---:|---:|---:|---:|---:|---|
| changed depth 1 | 481 | 334 | 11,002 | 8,795 | 22.9× | 26.3× | not met |
| changed depth 10 | 1,355 | 478 | 14,664 | 12,287 | 10.8× | 25.7× | not met |
| changed depth 100 | 15,017 | 2,530 | 72,341 | 49,043 | 4.8× | 19.4× | not met |
| cutoff depth 10 | 1,202 | 431 | 11,633 | 9,780 | 9.7× | 22.7× | not met |
| dynamic switch | 1,509 | 636 | 21,331 | 16,339 | 14.1× | 25.7× | not met |
| keyed data change 10k | 188,859 | 746 | 13,935,584 | 2,571,401 | 73.8× | 3,447× | not met |
| keyed data change 100k | 3,979,281 | 838 | 301,211,251 | 25,106,642 | 75.7× | 29,960× | not met |
| keyed membership 10k | 189,259 | 1,001 | — | — | — | — | not met |
| keyed membership 100k | 4,007,196 | 1,134 | — | — | — | — | not met |
| keyed child change 10k | 821,742 | 440 | 60,897,287 | 6,993,791 | 74.1× | 15,895× | not met |
| keyed child change 100k | 27,079,970 | 464 | 1,723,489,099 | 72,998,406 | 63.6× | 157,324× | not met |

The Eta-only wall-time rule is met on every row: each candidate median is far
below its pinned pre-redesign median.

The matched acceptance-matrix gates are not met. The best row is 8.9 times the
Incremental wall reference; the matrix allows 1.20. The remaining cost is
kernel-internal per-stabilization machinery: plan building, publish and
coalescing lists, two-pass bind freshness, and observer bookkeeping. That cost
belongs to issue 15 (node identity and index lifecycle), issue 16 (generic
typed value storage), and issue 13 (module and package ownership). Issue 14
carries the complete acceptance-matrix gate. The frozen gates stay unchanged.

Migration-time judgment calls, flagged for the record:

- `Runtime_mismatch` detection moved to timer creation. It is typed and
  attached to the timer's own runtime.
- Timer use from a dead runtime is a defect, not a typed error.
- Timer daemon forks no longer appear in the `Spi.daemon` census or the
  tracer. The daemon lifecycle stays internal to the edge driver.
- Stream offer and drop defects are buffered and surface at the next bridge
  operation.
- Disposal-hook defects propagate as raw exceptions.
- Crux staging model sets became thunks. Every synchronous Signal call at the
  Crux boundary is deferred behind `Effect.sync`. An eager `from_result` at
  record construction was caught by the Crux laws suite and removed.

Census deltas from issue 01: SB02, SB04, SB05, SB09, SB10, SB11, SB14, SB15,
SB16, SB17, SB18, SB19, and SB20 changed to the synchronous model. SB01, SB03,
SB06, SB07, SB08, SB12, SB13, and MB01 through MB12 are unchanged.
