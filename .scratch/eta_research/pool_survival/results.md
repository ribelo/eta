# Pool Survival Results

## Verdict

Library shape wins, but implementation should not start as a blind pool clone.

The evidence says Eta should own a generic pool primitive because Branch A and
Branch B hit the same hard lifecycle problems, while Branch B avoids copying
the same pool protocol into eta-http, eta-sql, eta-grpc, and eta-llm. The
dogfood run also found Eta gaps that should be fixed or deliberately accepted
before shipping a public Eta.Pool.

Status: library / blocked-by-Eta-gaps.

## Commands And Results

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_survival/runtime_smoke.exe
~~~

Result:

~~~text
branch_a_internal_pool cancel_waiter FAIL ... cancelled_waiters=1 ... waiting=0
branch_a_internal_pool workload PASS ... max_live=8 ... health_rejected=1 ... pool_shutdowns=92
branch_a_internal_pool idle_evict PASS ...
branch_b_eta_pool cancel_waiter FAIL ... cancelled_waiters=1 ... waiting=0
branch_b_eta_pool workload PASS ... max_live=8 ... health_rejected=1 ... pool_shutdowns=92
branch_b_eta_pool idle_evict PASS ...
pool_survival runtime smoke passed
~~~

The cancellation fixture fails at caller-visible cause quality, not cleanup:
both branches clean waiting=0 and increment cancelled_waiters=1, but
all_settled records Cause.Die containing nested Eta__Runtime.Raised_cause.

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_survival/treiber_stack_probe.exe
~~~

Result:

~~~text
treiber_stack_probe PASS lifo=true atomic=Stdlib.Atomic
~~~

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_survival/allocation_probe.exe
~~~

Result:

~~~text
branch_a_internal_pool allocation_probe count=1000 wall_ms=1 minor_words=516553 promoted_words=263 major_words=263 minor_collections=6 major_collections=3
branch_b_eta_pool allocation_probe count=1000 wall_ms=0 minor_words=515883 promoted_words=27 major_words=27 minor_collections=6 major_collections=3
~~~

Negative probes:

~~~text
atomic_portable_negative: Atomic.Portable is unbound; correct path is Portable.Atomic
oxcaml_conn_unique_negative: pooled conn is aliased, expected unique
oxcaml_borrow_effect_capture_negative: local borrow cannot be captured by global Effect.sync closure
~~~

Process-level smoke timing:

~~~text
Elapsed wall time: 0:00.12
Maximum resident set size: 35300 KB
~~~

## LOC

~~~text
 151 common.ml
 303 branch_a_internal_pool.ml
 326 branch_b_eta_pool.ml
 240 runtime_smoke.ml
  86 allocation_probe.ml
  33 treiber_stack_probe.ml
  36 oxcaml_borrow_positive.ml
1175 total
~~~

Branch B is slightly larger in the lab because it carries generic connection
hooks, but the implementation protocol is the same. If Branch A wins, that
protocol is duplicated in every future Eta IO consumer.

## Hypothesis Ledger

| Candidate | Why plausible | Evidence | Status |
| --- | --- | --- | --- |
| A. eta-http-private recipe | HTTP has protocol-specific h1/h2 pooling; request callers should not see Pool. | Runtime behavior can be implemented, but it uses the same lifecycle protocol and daemon/wait gaps as Branch B. | Dominated for Eta dogfooding. Keep eta-http public API pool-free, but do not copy the primitive privately. |
| B. public Eta.Pool primitive | Pool owns bounded storage, health, idle/lifetime eviction, shutdown, stats, cancellation cleanup. | Same runtime behavior as A with generic hooks; avoids cross-consumer duplication; can live inside packages/eta and use Private daemon legitimately. | Accepted shape, implementation deferred until gaps are handled. |
| C. OxCaml Treiber plus local unique borrow | LIFO warm reuse and scope-bound borrows are a strong OxCaml-shaped hypothesis. | Treiber LIFO works with Stdlib.Atomic and Portable.Atomic; sealed local borrow compiles; direct conn local unique and lazy Eta effect capture fail. The pool_choice lab compares Treiber LIFO, mutex LIFO/FIFO, and Eio.Stream FIFO. | Partial. LIFO is the leading idle-storage policy; Treiber/Portable.Atomic is the current cross-domain leader. Local-unique borrow API remains deferred. |

## Storage-Policy Comparison Evidence

Follow-up lab:

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_choice/storage_policy_bench.exe
~~~

Result summary:

- LIFO beats FIFO when warm reuse matters. In the Eio-fiber warm workload,
  Treiber LIFO and mutex LIFO hit 99.99% warm reuse; mutex FIFO and Eio.Stream
  FIFO hit 0%.
- Treiber LIFO and mutex LIFO are close in same-domain Eio. Treiber was 12-13
  ms in the representative runs; mutex LIFO was 13-14 ms.
- FIFO shapes have perfect idle-entry fairness, but they lose the warm-cache
  behavior eta-http wants.
- Raw domain stress favors Treiber over mutex LIFO, but that stress executable
  uses raw Domain.spawn and is not the public API proof.
- The full-protocol pool_choice lab repeats the comparison through Eta
  acquire/use/release with health rejection, wait cancellation cleanup, idle
  eviction, and shutdown. In the warm-cache protocol, Treiber LIFO and mutex
  LIFO kept 3,200 warm hits and 64 cold hits; mutex FIFO kept only 40 warm hits
  and 3,224 cold hits.

Mode-safety probes:

~~~text
domain_safe_treiber_positive PASS
domain_safe_mutex_counter_positive PASS
domain_safe_mutex_list_negative: mutable values field rejected under Domain.Safe.spawn
domain_safe_stream_negative: Eio.Stream.take_nonblocking is nonportable under Domain.Safe.spawn
~~~

Interpretation:

- For eta-http v1, Eta.Pool should be same-domain and use mutex LIFO. Real Eio
  connection handles are nonportable, and the pool_choice negative fixture shows
  a Portable.Atomic Treiber stack cannot store an Eio-shaped connection payload
  without a portable constraint.
- Treiber LIFO over Portable.Atomic remains the current best candidate only for
  a future portable-payload/cross-domain pool shape.
- Eio.Stream FIFO should not be the idle-storage primitive; keep it as
  wait-queue prior art only.

## Shipped Eta.Pool Probe

Artifact:

~~~sh
nix develop -c dune build scratch/eta_research/pool_survival/eta_pool_probe.exe
nix develop -c _build/default/scratch/eta_research/pool_survival/eta_pool_probe.exe
~~~

Latest local result:

~~~text
eta_pool_sequential capacity=32 acquirers=1 total=10000 elapsed_ms=17 minor_words=17954275 words_per_acquire_release=1795.4 p50_acquire_us=1 p99_acquire_us=3 warm_reuse_hit_rate=0.9999 opened=1 closed=1 active=0 idle=0 waiting=0 health_rejected=0 cancelled_waiters=0 max_live=1
eta_pool_contended capacity=64 acquirers=128 total=12800 elapsed_ms=285 minor_words=34310639 words_per_acquire_release=2680.5 p50_acquire_us=1167 p99_acquire_us=1805 warm_reuse_hit_rate=0.9949 opened=65 closed=65 active=0 idle=0 waiting=0 health_rejected=1 cancelled_waiters=0 max_live=64
~~~

Interpretation:

- The shipped pool keeps live connections bounded under 128 contending
  acquirers with capacity 64.
- Warm reuse is effectively saturated in both sequential and contended runs.
- The hot path is not low-allocation: cancellation guards, Effect nodes,
  acquire/release finalizers, health-check spans, and metric updates are
  visible in the per-acquire word count.
- This is still the right v1 tradeoff. The guard prevents leaks if a fiber is
  cancelled after a resource is reserved but before the outer acquire_release
  finalizer is installed.

## Eta.Pool vs Eio.Pool Hot-Loop Comparison

Artifact:

~~~sh
nix develop -c dune build scratch/eta_research/pool_survival/pool_compare_probe.exe
nix develop -c _build/default/scratch/eta_research/pool_survival/pool_compare_probe.exe
~~~

Scope:

- Same fake connection counters and health rejection shape.
- Same-domain Eio fibers only.
- Hot acquire/use/release loop measured after pool creation.
- Eta shutdown and idle eviction are not measured here because Eio.Pool has no
  equivalent shutdown/lifetime surface.
- Eio.Pool uses direct-style synchronous validate/dispose; Eta.Pool uses lazy
  Effect.t acquisition, release, health check, finalizers, and observability
  effect nodes.

Latest local result:

~~~text
eta_pool_sequential capacity=32 acquirers=1 iterations=100000 hold_ms=0 total=100000 elapsed_ms=135 minor_words=141102960 promoted_words=334921 major_words=335946 words_per_acquire_release=1411.0 p50_acquire_us=1 p99_acquire_us=2 warm_reuse_hit_rate=1.0000 opened=1 closed=0 live=1 max_live=1
eio_pool_sequential capacity=32 acquirers=1 iterations=100000 hold_ms=0 total=100000 elapsed_ms=8 minor_words=3526632 promoted_words=775464 major_words=775464 words_per_acquire_release=35.3 p50_acquire_us=0 p99_acquire_us=1 warm_reuse_hit_rate=1.0000 opened=1 closed=0 live=1 max_live=1
eta_pool_contended capacity=64 acquirers=128 iterations=100 hold_ms=1 total=12800 elapsed_ms=285 minor_words=29126535 promoted_words=1426984 major_words=1428009 words_per_acquire_release=2275.5 p50_acquire_us=1156 p99_acquire_us=1676 warm_reuse_hit_rate=0.9949 opened=65 closed=1 live=64 max_live=64
eio_pool_contended capacity=64 acquirers=128 iterations=100 hold_ms=1 total=12800 elapsed_ms=280 minor_words=4384038 promoted_words=137737 major_words=137737 words_per_acquire_release=342.5 p50_acquire_us=1040 p99_acquire_us=1973 warm_reuse_hit_rate=0.9949 opened=65 closed=1 live=64 max_live=64
~~~

One-hour optimization pass:

- Retained: cache Pool observability attrs in the Pool record. This removed
  repeated list construction and moved sequential allocation from 1728.0 to
  1608.0 words/op.
- Rejected: wrap acquisition in one `Effect.uninterruptible`. It reduced
  apparent structure but broke waiter cancellation accounting
  (cancelled_waiters stayed 0 instead of 1).
- Retained: batch gauge metrics as one private Metric_updates node. This moved
  sequential allocation to 1560.0 words/op and contended allocation to about
  2433 words/op.
- Retained: add private Named_attrs so Pool spans do not need two Annotate
  effect nodes for fixed attrs. This moved sequential allocation to 1544.0
  words/op and contended allocation to about 2414 words/op.
- Retained: lazy private Metric_updates_lazy. In the no-meter hot path the
  runtime now skips metric snapshots, metric value construction, and stat
  locks. This was the biggest win, moving sequential allocation to about
  1428.0 words/op.
- Retained: split the fixed warm-reuse acquisition guard from the open-new
  mutable-release guard. This removed one ref/closure from the common path and
  moved sequential allocation to about 1420.0 words/op.
- Retained: skip idle expiry scans entirely when no idle_lifetime or
  max_lifetime is configured. This avoids a hot gettimeofday/list scan and
  moved the final run to 1411.0 words/op sequential and 2275.5 words/op
  contended.
- Rejected: branch the last_used_ms write when no expiry policy exists. It did
  not move allocation or elapsed time enough to justify the extra branch.

Interpretation:

- Sequential hot-loop wall time: Eta.Pool is about 17x slower than Eio.Pool in
  this no-IO microbenchmark.
- Sequential allocation: Eta.Pool allocates about 40x more minor words per
  checkout/release.
- Contended with 1 ms work: wall time is effectively tied because the hold time
  dominates. Eta still allocates about 6.6x more minor words per checkout.
- Reuse quality and max-live bounds are identical in this workload.

Conclusion: use Eio.Pool for direct-style local resource reuse. Eta.Pool is not
the low-level performance floor; it buys Eta-native typed errors, lazy
Effect.t callbacks, effectful health checks, scoped cancellation, shutdown, and
observability. That tradeoff is acceptable for h1/SQL connection checkout but
not for ultra-hot object pools or h2 per-frame routing.

The precise status is: LIFO is the best-tested idle policy. Mutex LIFO is the
best v1 candidate for eta-http and arbitrary same-domain Eio connections.
Treiber over Portable.Atomic is the current leader only for a
portable-payload/cross-domain Pool. The shipped same-domain Eta.Pool uses
mutex LIFO and records its own package-level probe above.

## Decision Diary

### V-Pool-Survival-1 - Resource is not the pool primitive

Decision: do not extend Resource into a pool.

Evidence: the lab requires max size, idle list, health check, shutdown, wait
queue, and per-connection stats. Resource remains the V-Rs cached-loader
abstraction.

### V-Pool-Survival-2 - Pool should be Eta-owned, not eta-http-private

Decision: accept the library shape.

Evidence: Branch A and B implement the same lifecycle protocol. The generic
branch is only 23 LOC larger in the lab and avoids duplicating the same subtle
wait/shutdown/health protocol across future Eta IO consumers.

Counterevidence: HTTP/2 multiplexer semantics are not identical to HTTP/1.1
connection checkout. This does not make Pool the eta-http public API; eta-http
consumes Pool internally where it fits and keeps protocol selection at the
request layer.

### V-Pool-Survival-3 - Do not ship local-unique borrow as v1 API

Decision: keep the OxCaml borrow design deferred.

Evidence: the exact conn local unique API fails from aliased pool storage. An
abstract local-unique borrow handle compiles, but it cannot be captured into
Eta's lazy Effect.t, which is how effectful connection operations are built
today.

### V-Pool-Survival-4 - Cancellation cause quality is an Eta bug/gap

Decision: file the cancellation fixture as an Eta primitive/runtime gap before
depending on Pool for production HTTP.

Evidence: both branches clean the wait slot, but all_settled records a
Cause.Die containing nested Raised_cause exceptions under timeout/scoped
resource cancellation.

### V-Pool-Survival-5 - Pool implementation task is allowed, but gated

Decision: create a separate Eta.Pool implementation task, gated on the gaps in
dogfood_gaps.md.

Evidence: the primitive shape is valuable, but the dogfood run found runtime,
typing, and measurement work that should not be silently buried in eta-http.
