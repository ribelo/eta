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

Evidence still needed before shipping Eta.Pool:

- repeat these measurements against the shipped Eta.Pool implementation once it
  exists.

The precise status is: LIFO is the best-tested idle policy. Mutex LIFO is the
best v1 candidate for eta-http and arbitrary same-domain Eio connections.
Treiber over Portable.Atomic is the current leader only for a
portable-payload/cross-domain Pool. Shipped Eta.Pool still needs its own
package-level benchmark gate.

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
