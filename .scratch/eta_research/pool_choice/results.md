# Eta.Pool Storage Choice Results

## Interim Verdict

The best idle-storage policy among the tested candidates is LIFO, not FIFO.

For eta-http dogfooding, the best current v1 implementation candidate is
mutex LIFO in the owning Eio domain. The reason is not throughput: Treiber LIFO
and mutex LIFO are tied in same-domain protocol runs. The reason is payload
mode. Real eta-http connections contain Eio handles, and a Treiber stack over
Portable.Atomic cannot store those nonportable values without making the Pool
API mode-constrained.

The full-protocol lab now repeats the storage comparison inside an Eta-shaped
bounded acquire/use/release loop. FIFO remains rejected for idle connection
reuse when warm connections are materially cheaper. Treiber LIFO and mutex LIFO
are effectively tied in same-domain Eio. Treiber remains the leading candidate
only for a separate portable-payload/cross-domain pool shape.

## Commands

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_choice/storage_policy_bench.exe
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_choice/pool_protocol_bench.exe
~~~

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_choice/domain_safe_treiber_positive.exe
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_choice/domain_safe_mutex_counter_positive.exe
~~~

Negative fixtures:

~~~sh
nix develop .#oxcaml -c ocamlfind ocamlc -thread -c scratch/eta_research/pool_choice/domain_safe_mutex_list_negative.ml
nix develop .#oxcaml -c ocamlfind ocamlc -package eio -thread -c scratch/eta_research/pool_choice/domain_safe_stream_negative.ml
nix develop .#oxcaml -c ocamlfind ocamlc -package portable,eio -c scratch/eta_research/pool_choice/portable_atomic_eio_conn_negative.ml
~~~

## Representative Benchmark Result

Workload:

- 64 idle resources;
- 16 workers;
- 8,000 acquire/use/release loops per worker;
- same-domain Eio workers yield while holding the resource, matching request
  bodies that suspend during IO;
- warm_reuse_matters makes recently returned resources cheaper than older idle
  resources.

Second run:

| Mode | Scenario | Candidate | Wall ms | Warm % | p99 us | Minor words | Promoted words | Active items | Min uses | Max uses | CAS retries |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| eio_fibers | neutral_overhead | treiber_lifo_portable_atomic | 13 | 0.00 | 2.86 | 11,319,541 | 5,066 | 16 | 0 | 8,000 | 0 |
| eio_fibers | neutral_overhead | mutex_lifo | 13 | 0.00 | 2.15 | 12,214,710 | 4,803 | 16 | 0 | 8,000 | 0 |
| eio_fibers | neutral_overhead | mutex_fifo | 15 | 0.00 | 2.15 | 12,214,710 | 388,413 | 64 | 2,000 | 2,000 | 0 |
| eio_fibers | neutral_overhead | eio_stream_fifo | 16 | 0.00 | 2.15 | 11,318,710 | 388,030 | 64 | 2,000 | 2,000 | 0 |
| eio_fibers | warm_reuse_matters | treiber_lifo_portable_atomic | 12 | 99.99 | 2.15 | 11,318,710 | 4,497 | 16 | 0 | 8,000 | 0 |
| eio_fibers | warm_reuse_matters | mutex_lifo | 14 | 99.99 | 2.15 | 12,214,710 | 4,803 | 16 | 0 | 8,000 | 0 |
| eio_fibers | warm_reuse_matters | mutex_fifo | 25 | 0.00 | 4.05 | 12,214,710 | 388,413 | 64 | 2,000 | 2,000 | 0 |
| eio_fibers | warm_reuse_matters | eio_stream_fifo | 25 | 0.00 | 3.10 | 11,318,710 | 388,030 | 64 | 2,000 | 2,000 | 0 |
| domains | neutral_overhead | treiber_lifo_portable_atomic | 25 | 0.00 | 13.11 | 1,197,555 | 1,626 | 13 | 0 | 17,346 | 516,194 |
| domains | neutral_overhead | mutex_lifo | 52 | 0.00 | 41.96 | 1,797,804 | 1,720 | 16 | 0 | 9,739 | 0 |
| domains | neutral_overhead | mutex_fifo | 81 | 0.00 | 44.82 | 1,797,804 | 385,461 | 64 | 1,985 | 2,019 | 0 |
| domains | neutral_overhead | eio_stream_fifo | 77 | 0.00 | 40.77 | 901,804 | 385,036 | 64 | 1,979 | 2,025 | 0 |
| domains | warm_reuse_matters | treiber_lifo_portable_atomic | 47 | 90.00 | 20.03 | 1,647,049 | 1,499 | 14 | 0 | 10,372 | 827,420 |
| domains | warm_reuse_matters | mutex_lifo | 57 | 76.77 | 38.86 | 1,797,804 | 1,737 | 16 | 0 | 10,278 | 0 |
| domains | warm_reuse_matters | mutex_fifo | 88 | 0.00 | 42.92 | 1,797,804 | 385,500 | 64 | 1,983 | 2,018 | 0 |
| domains | warm_reuse_matters | eio_stream_fifo | 87 | 0.00 | 46.01 | 901,804 | 385,044 | 64 | 1,987 | 2,014 | 0 |

The domain benchmark uses raw Domain.spawn inside the executable. Treat it as
stress evidence, not as proof of the public API shape. The separate
Domain.Safe.spawn compile probes below are the mode-safety evidence.

## Domain.Safe Evidence

Positive:

~~~text
domain_safe_treiber_positive PASS
domain_safe_mutex_counter_positive PASS
~~~

Interpretation:

- Portable.Atomic Treiber storage can be captured by Domain.Safe.spawn.
- Mutex.t itself is not the blocker when the protected state is mode-safe.

Negative:

~~~text
domain_safe_mutex_list_negative.ml:
Error: This value is "contended" ... expected to be "uncontended"
because its mutable field "values" is being written.

domain_safe_stream_negative.ml:
Error: The value "Eio.Stream.take_nonblocking" is "nonportable"
but is expected to be "portable".

portable_atomic_eio_conn_negative.ml:
Error: This value is "nonportable" ... field "stream" ... expected to be
"portable".
~~~

Interpretation:

- the naive mutex-list/FIFO implementation is only a same-domain candidate unless
  it is redesigned around a mode-safe mutable container;
- Eio.Stream should not be the idle-storage primitive for cross-domain
  Eta.Pool. It may still be useful as a wait-queue primitive inside one Eio
  runtime boundary.
- Portable.Atomic storage is not a generic answer for eta-http connections:
  storing an Eio-shaped connection payload fails because the payload is
  nonportable.

## Full Protocol Evidence

Command:

~~~sh
nix develop .#oxcaml -c dune exec scratch/eta_research/pool_choice/pool_protocol_bench.exe
~~~

This executable compares Treiber LIFO, mutex LIFO, and mutex FIFO inside a
bounded pool protocol with:

- max-size admission;
- acquire/use/release through Eta Effect.acquire_release;
- health rejection;
- wait-loop cancellation cleanup;
- idle eviction;
- shutdown drain;
- allocation measurement.

Representative result:

| Scenario | Candidate | Wall ms | Minor words | Warm | Cold | Wait loops | Cancelled waiters | Opened | Closed | CAS retries |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| protocol_churn | treiber_lifo_portable_atomic | 805 | 3,740,053 | 3,192 | 8 | 2,197 | 0 | 9 | 9 | 0 |
| protocol_churn | mutex_lifo | 802 | 3,789,378 | 3,192 | 8 | 2,197 | 0 | 9 | 9 | 0 |
| protocol_churn | mutex_fifo | 691 | 3,768,908 | 3,172 | 28 | 2,191 | 0 | 9 | 9 | 0 |
| protocol_warm_cache | treiber_lifo_portable_atomic | 412 | 2,242,122 | 3,200 | 64 | 0 | 0 | 65 | 65 | 0 |
| protocol_warm_cache | mutex_lifo | 407 | 2,266,496 | 3,200 | 64 | 0 | 0 | 65 | 65 | 0 |
| protocol_warm_cache | mutex_fifo | 527 | 2,322,384 | 40 | 3,224 | 0 | 0 | 65 | 65 | 0 |

Cancellation and lifetime smoke:

~~~text
cancellation_smoke ... outcomes=ok:holder_done,ok:cancelled ... waiting=0 cancelled_waiters=1 opened=1 closed=1 live=0
idle_eviction_smoke ... total=0 idle=0 in_use=0 opened=1 closed=1 live=0
~~~

Interpretation:

- The saturated churn workload does not distinguish storage policy much because
  all live connections stay hot.
- The warm-cache protocol does distinguish policy: LIFO keeps the active set
  hot after prefill; FIFO cycles through cold idle entries.
- Treiber LIFO and mutex LIFO remain tied in same-domain Eio. Treiber's current
  advantage is OxCaml mode safety, not same-domain throughput.
- The protocol entry shape only compiled cleanly after connection flags and
  timing fields were represented as portable integer atomics. Raw
  Portable.Atomic.get returns contended values, so Eta.Pool should hide this
  mode friction behind private helpers.

## Candidate Ledger

| Candidate | Strongest case | Evidence against | Status |
| --- | --- | --- | --- |
| Treiber LIFO over Portable.Atomic | Hot reuse, no mutex, compiles under Domain.Safe.spawn for portable payloads, tied with mutex LIFO in full same-domain protocol. | Cannot store Eio-shaped connection payloads without a portable constraint; high CAS retries under raw domain stress; allocates stack nodes per release to avoid ABA; more mode friction than mutex LIFO. | Conditional: use only for portable-payload/cross-domain pool shapes. |
| Mutex LIFO | Same warm-reuse behavior as Treiber in Eio fibers and full protocol; simple; stores ordinary same-domain Eio connection handles. | Naive mutable-list storage fails Domain.Safe.spawn; domain stress is slower than Treiber; still starves old idle entries. | Best v1 eta-http/Eta.Pool candidate if Pool is same-domain. |
| Mutex FIFO | Excellent idle-entry fairness; boring implementation. | Loses warm reuse by construction and is materially slower in warm-cache protocol. | Rejected for idle storage unless fairness becomes the primary invariant. |
| Eio.Stream FIFO | Existing Eio primitive, thread-safe docs, simple FIFO semantics. | Loses warm reuse; take_nonblocking is nonportable under Domain.Safe.spawn; promoted-word count is high in this workload. | Rejected for idle storage; keep as possible wait-queue prior art. |
| Vyukov bounded MPMC | Plausible if Treiber CAS retries dominate under real contention. | Not needed by current numbers; more complex than the observed bottleneck justifies. | Deferred. |
| Per-domain caches | Could reduce contention at high domain counts. | Overkill before an integrated benchmark shows one shared pool is the bottleneck. | Deferred. |

## Decision So Far

Eta.Pool should not use FIFO for idle connection reuse unless a future
requirement makes fairness among idle entries more important than warm reuse.

For v1 eta-http dogfooding, Eta.Pool should be same-domain and use mutex LIFO
for idle connection storage. Do not promise cross-domain use for arbitrary
connections, because Eio connection handles are nonportable and Portable.Atomic
storage would force that constraint into the API.

If Eta later wants a cross-domain pool for portable payloads, that should be a
separate mode-constrained design. In that design, Treiber LIFO over
Portable.Atomic is the current leading storage candidate.

The public API should still remain the conservative callback shape from the
pool-survival ADR. This lab does not change the earlier result that local/unique
borrow handles do not yet compose with lazy Eta effects.

## API Shape Verdict

Commands:

~~~sh
nix develop .#oxcaml -c dune build scratch/eta_research/pool_survival/oxcaml_borrow_positive.exe
nix develop .#oxcaml -c ocamlc -I _build/default/packages/eta/.eta.objs/byte -c scratch/eta_research/pool_survival/oxcaml_conn_unique_negative.ml
nix develop .#oxcaml -c ocamlc -I _build/default/packages/eta/.eta.objs/byte -c scratch/eta_research/pool_survival/oxcaml_borrow_effect_capture_negative.ml
~~~

Evidence:

- oxcaml_borrow_positive builds: a sealed local borrow handle can be passed to a
  callback when the returned Eta effect does not capture that local value.
- oxcaml_conn_unique_negative fails: a connection read from aliased pool storage
  cannot be passed as conn @ local unique.
- oxcaml_borrow_effect_capture_negative fails: a local borrow cannot be captured
  by Effect.sync because the closure stored in Effect.t must be global.

Verdict:

- v1 Eta.Pool should expose a conservative callback over the connection value:
  with_resource : t -> (conn -> effect) -> effect.
- Do not expose conn @ local unique. Pool storage makes the connection aliased.
- Do not expose a local/unique borrow handle for effectful work yet. It is
  plausible for a future synchronous-only API, but current Eta Effect.t cannot
  express useful network operations that capture the local borrow.

## Remaining Evidence

- Fix or account for the existing all_settled/timeout cancellation cause bug.
- Confirm the same-domain-only contract in the shipped Eta.Pool API docs.
- Reopen cross-domain storage only if Eta adds a portable-payload Pool variant
  or eta-http stops storing Eio handles in pooled values.
- Repeat the benchmark against the shipped Eta.Pool implementation once it
  exists; this lab is still scratch evidence, not a package gate.
