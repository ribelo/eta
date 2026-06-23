# research.md — eta keyed cache, source matrix

Evidence matrix: each source → claims relevant to the 8 questions in
`objective.md`, with confidence (High / Med / Low) and how to verify.
Retrieval/read dates are 2026-06-23 unless noted.

Confidence legend:
- **High** = read the implementation or spec directly; behavior is unambiguous.
- **Med** = read docs/summaries or a derivative; behavior credible but verify
  the exact API before depending on it.
- **Low** = second-hand or single-source; treat as a lead, not a fact.

---

## A. Eta-internal prior art (read directly, High confidence)

### A1. `lib/eta/pool.mli` + `lib/eta/pool.ml` (645 lines) — the design template

The Pool is the closest thing Eta already ships to a keyed cache: bounded
capacity, TTL/idle eviction, cooperative waiter coordination, stats, typed
failures, runtime clock. This is the single most important prior art.

| Claim | Evidence | Conf |
|---|---|---|
| Pool owns a bounded set of resources; `max_size` bounds idle+checked-out+opening+closing | `pool.mli create ~max_size ~max_idle` doc; invariant in docstring | High |
| Idle resources stored LIFO for warm reuse; waiters use a private wake-one mechanism | `pool.mli` top docstring; `sem : Semaphore.t` + wake-one in `pool.ml` | High |
| **Waiters block via `Semaphore.acquire t.sem 1`** (cooperative, cancellable) | `pool.ml` line ~522 `Semaphore.acquire t.sem 1`; `pool.ml:579 Semaphore.make ~permits:max_size` | High |
| TTL eviction: `idle_lifetime`, `max_lifetime`; a runtime daemon evicts expired idle resources at `idle_check_interval` (default 1s) | `pool.mli create ?idle_lifetime ?max_lifetime ?idle_check_interval` | High |
| Locking is `Sync_lock.t` (portable CAS), **not** stdlib `Mutex` | `pool.ml:35 mutex : Sync_lock.t`; `Sync_lock.use t.mutex` everywhere | High |
| Two-phase critical section: collect expired/victim **under the lock** (mutating mutable lists), then run effects (close/release) **outside** the lock | `take_expired_idle_locked` + `[\`Close_expired of ...]` action return; close happens outside | High |
| Clock comes from the runtime contract: `now_ms t = t.shutdown_contract.Runtime_contract.now_ms ()` | `pool.ml:51`; `runtime_contract.mli:40 now_ms : unit -> int` | High |
| Expiry test: `duration_expired ~now duration started_at = now - started_at >= Duration.to_ms duration` | `pool.ml:53-54` | High |
| `entry` records `created_ms`, `last_used_ms` (ints) | `pool.ml:18,398-399` | High |
| Per-entry freshness via LIFO + `last_used_ms` refresh on acquire | `pool.ml` acquire path | High |
| Stats snapshot is lock-and-copy: `Effect.sync (fun () -> Sync_lock.use t.mutex @@ fun () -> stats_locked t)` | `pool.ml:96` | High |

**Transfer to cache:** capacity-bound map + per-entry `expires_at_ms` (int) +
`Sync_lock` two-phase collect/evict + `Semaphore`-based waiters + runtime-clock
expiry test + stats snapshot. This is essentially a keyed cache already; the
cache generalizes "connection per checkout" to "value per key."

### A2. `lib/eta/sync_lock.mli` — the lock primitive

| Claim | Evidence | Conf |
|---|---|---|
| `Sync_lock` is a tiny lock for short effect-free critical sections | `sync_lock.mli` docstring ("do not perform effects, sleeps, promise awaits") | High |
| API: `create / lock / unlock / use` | `sync_lock.mli` | High |
| Portable across native and js_of_ocaml (backed by `Atomic` CAS, no `threads`) | `sync_lock.ml` uses `Atomic`; `lib/eta` does not depend on `threads` (only `lib/eio` does) | High |

**Transfer to cache:** the cache's mutation critical section (map insert/remove,
entry state transitions, waiter-list edits) must be effect-free and run under
`Sync_lock`. Lookups/effects (the user `lookup` effect) run **outside** the lock.

### A3. Eta effect/runtime surface relevant to a cache

| Claim | Evidence | Conf |
|---|---|---|
| `Effect.now : (int,'err) t` reads the active runtime clock in ms; overridable via runtime `?now_ms` | `effect.mli:374-376` | High |
| `Effect.sleep : Duration.t -> (unit,'err) t`; overridable via `?sleep` | `effect.mli:378-380` | High |
| `Effect.daemon : (unit,'err) t -> (unit,'err) t` starts runtime-owned finite background work on the outer switch | `effect.mli:541-551`; `Expert.fork_daemon` | High |
| `Effect.with_background` for request-scoped background work | `effect.mli:535` | High |
| `Exit.t = Ok of 'a \| Error of 'err Cause.t` | `exit.mli:4-5` | High |
| `Channel` is bounded FIFO send/recv, **same-domain cooperative**; `recv` blocks the fiber while empty; `close_with_error` wakes receivers with a typed error | `channel.mli` docstring + `recv` doc | High |
| `Semaphore` cooperative permits with cancellation + `cancelled_waiters` accounting | `semaphore.mli` | High |
| `Mutable_ref` is a `[@@unboxed]` Atomic cell: `compare_and_set`, `update` (retries on CAS), `get_and_set` | `mutable_ref.mli` | High |
| Eta has **no `Promise`/`Deferred` on the public `Effect` surface** (no `Effect.make_promise`). `effect_concurrent.ml` has only fork-join combinators (`par`, `par_collect`, `race`, `for_each_par`). | grep of `effect.mli` + `effect_concurrent.ml` | High |
| **CORRECTION (supersedes the earlier "no Deferred" claim):** the `Runtime_contract` **does** expose a dual-platform one-shot promise. `type 'a promise`, `type 'a resolver`, `create_promise : unit -> 'a promise * 'a resolver`, `resolve_promise : 'a resolver -> 'a -> unit`, `await_promise : 'a promise -> 'a`. `Runtime_contract` is *"intentionally backend-neutral … without committing root `eta` to Eio, Unix, domains, or any JavaScript substrate."* | `runtime_contract.mli` (types + record fields + `RUNTIME` sig) | High |
| Effects reach the contract via `Effect.Expert.contract : context -> Runtime_contract.t`. | `effect.mli:619-623` | High |
| Pool already uses the runtime promise for shutdown: `create_promise ()` → `(promise, resolver)`; `await_promise promise`; `resolve_promise resolver ()`. This is the exact recipe a per-key cache entry copies. | `pool.ml:45-47,208,561-562,617-618` | High |
| The promise is implemented on **both** backends: native `eta_eio` via `let await_promise = Eio.Promise.await`; JS `eta_jsoo` via a **custom cooperative promise** (`Pending callbacks \| Settled result`, `subscribe`, `await ?on_cancel`, scheduled via `queueMicrotask`/`setTimeout`). | `eta_eio.ml:251`; `eta_jsoo.ml:176-188,244,249` | High |
| **Prior art proves single-flight on this primitive already runs.** `.scratch/deferred_pubsub_research/runtime_smoke.ml` builds a `Deferred_probe` over `Eio.Promise` and its alcotest suite passes: `[OK] deferred 0 first completion wins` (many awaiters share one completion) and `[OK] deferred 1 failure replays to late awaiter` (failure caching). Ran via `nix develop -c dune exec scratch/deferred_pubsub_research/runtime_smoke.exe` (see `run.out`). | local scratch lab | High |
| **Dedicated native fixture for this decision (NEW, 2026-06-23).** `.scratch/evidence/eta-cache-research/eta_cache_fixture/` (cache_probe.ml + runtime_smoke.ml) implements the per-key protocol over a one-shot promise on Eta's native runtime and is **6/6 green**: single-flight exactly-once under 8-way contention, failure cached-and-replayed, hit/miss, invalidate, TTL expiry (injectable clock), TTL=0 never-caches, capacity eviction. `nix develop -c dune exec --root .scratch ./evidence/eta-cache-research/eta_cache_fixture/runtime_smoke.exe` (see `fixture_run.out`). **Native-only** (uses `Runtime_contract` through the eio backend). | local fixture | High |

**Revised consequence:** both Effect `Cache.ts` and zio-cache depend on a
per-key `Deferred`/`Promise` for single-flight. Eta **already has** a
backend-neutral one-shot promise in `Runtime_contract`, implemented on both the
eio (native) and jsoo backends, and a prior scratch lab already proved
exactly-once completion + failure replay on it. So single-flight does **not**
need a `Semaphore`-latch and does **not** require inventing a new primitive:
map Effect's per-key `Deferred` directly onto `Runtime_contract` promise.
What is genuinely missing is only a *public* `Effect.make_promise`/`await`
wrapper (a small, optional surface) — see recommendation.md §6.

### A4. `porting-candidates.md` §2.14 and §9 (this worktree)

| Claim | Evidence | Conf |
|---|---|---|
| Single-effect `cached`/`cached_with_ttl`/`memoize` is the small, separable part; keyed `Cache` is a **heavier, separate concern — OUT-OF-SCOPE for core, candidate for an optional package** | §2.14 last paragraph; §9 bullet "`Cache` (full keyed LRU/TTL cache) … optional package, not core" | High |
| Keyed cache must respect the package boundary: optional `eta_cache`, not root `eta` | §9 + repo `AGENTS.md` package boundary policy | High |

This is what scopes the whole investigation: the recommendation's package
answer is **already constrained to optional `eta_cache`**; the research decides
whether/how to build it.

---

## B. Effect-TS keyed `Cache.ts` (read implementation directly, High confidence)

Source: local reference
`/home/ribelo/projects/ribelo/ocaml/Eta/.reference/effect-smol/packages/effect/src/Cache.ts`
(1295 lines). Verified current against Effect v4 docs (Exa, 2026-06-23):
the local file matches the public `make({capacity,timeToLive,lookup})`,
`get`/`getEither`/`refresh`/`set`/`invalidate` API and the
"least-recently-used eviction when at capacity" semantics. (`getEither` is a
newer addition; the core mechanism is unchanged.)

| Claim | Evidence (Cache.ts) | Conf |
|---|---|---|
| Backing store is `map: MutableHashMap<Key, Entry<A,E>>` with insertion order | interface lines ~104-110 | High |
| `Entry { expiresAt: number \| undefined; deferred: Deferred<A,E> }` — **one Deferred per key** | interface lines ~130-133 | High |
| **Single-flight:** on miss, create a new `Deferred`, insert, run `lookup`, `onExit` completes the deferred with the `Exit`; all concurrent getters `await` the same deferred | `get` impl ~405-440 | High |
| **Failure caching:** the deferred is completed with the failure `Exit`; getters all receive it; entry persists until TTL/invalidation | same `onExit` writes `expiresAt` from `timeToLive(exit,key)` regardless of Ok/Error | High |
| **Per-result TTL:** `timeToLive: (exit, key) => Duration`; stored as `expiresAt = clock.currentTimeMillisUnsafe() + ttl` using the **per-fiber clock** | `get`/`refresh`/`set` `onExit`; `hasExpired` uses `fiber.getRef(ClockRef)` | High |
| TTL of zero removes the entry; TTL of Infinity means never-expire | `Duration.isZero` → remove; `isFinite` guard | High |
| **Lazy expiry:** no sweeper/daemon; `hasExpired` checked in `get`/`getOption`/`has` on access | `hasExpired` + no timer/schedule | High |
| **Eviction = LRU-by-reinsertion:** on a hit, remove the key and re-insert it (moves it to the end); `checkCapacity` removes from the front (oldest insertion order) | `get` hit branch: `remove` then `set`; `checkCapacity` iterates map front-to-back | High |
| `refresh(key)` always re-runs lookup with a new deferred; **concurrent `get` callers during refresh still get the OLD entry** (the map is only overwritten after the new lookup completes) | `refresh` impl ~1075-1107: `existing` flag; re-`set` only after `onExit` | High |
| `set(key,value)` inserts a pre-resolved deferred (manual populate) | `set` impl ~712-735 | High |
| `invalidate(key)` removes the map entry | `invalidate` impl ~884-889 | High |

**Transfer to cache:** the deferred-per-key + per-result-TTL + lazy-expiry +
reinsertion-LRU model maps cleanly onto Eta: the per-key `Deferred` becomes a
`Runtime_contract` promise (§A3 correction — Eta *does* have a dual-platform
one-shot promise), and a dedicated native fixture (`eta_cache_fixture`) already
proves single-flight + failure caching on it. The one Effect detail to **drop**
is reinsertion-LRU: it allocates on every hit, which violates the objective's
low-allocation goal; use intrusive LRU nodes instead (recommendation §4/§5).

---

## C. ZIO `Cached.scala` (read directly, High confidence) — single-value, NOT keyed

Source: local `.reference/zio/core/shared/src/main/scala/zio/Cached.scala` (76
lines). `Cached[Error,Resource]` is a **single-value** cache (`ZIO#cached`),
distinct from zio-cache's keyed `Cache`. `Cached.manual`/`auto`:
`ScopedRef[Exit[Error,Resource]]`; `get = ref.get.unexit`; `refresh = ref.set(acquire.exit)`.
This is the ZIO analogue of Eta's **single-effect** `cached` family (objective
§2.14), not the keyed cache. Included to avoid conflating the two.

---

## D. zio-cache keyed `Cache` (Exa, 2026-06-23) — Med/High

Sources:
- https://zio.dev/zio-cache/cache (retrieved 2026-06-23)
- https://github.com/zio/zio-cache (retrieved 2026-06-23)
- https://zio.github.io/zio-cache/docs/overview/overview_index (retrieved 2026-06-23)
- (Earlier branch read `Cache.scala` source directly; summaries consistent.)

| Claim | Source | Conf |
|---|---|---|
| `Cache[Key,Error,Value]` built from `Lookup[Key,Environment,Error,Value]`; `get(k)` returns cached or computes via lookup, stores, returns | docs + repo README | High |
| **Concurrency:** multiple fibers requesting the same missing key → **one computation, shared**; others block semantically without blocking OS threads | docs | High |
| **Failure caching:** if lookup fails or is interrupted, the failure is cached; **interruption removes the key so it can be retried** | docs "Failure behavior" | High |
| TTL: values expire; can be derived from the lookup result | docs + overview | High |
| **Policy framework (newer than the simple LRU reference):** two-part composable policy — `Priority` (optional removal when space is needed; order of eviction) + `Evict` (mandatory removal based on entry validity/time, independent of space) | docs + README "Composition Caching Policy" | Med |
| `CacheStats`: entries, memory size, hits, misses, loads, evictions, total load time | docs | Med |
| Core API: `cacheStats, contains, entryStats, invalidate, invalidateAll, refresh, size` | docs | High |
| Implementation (from earlier source read): tri-state entry `Pending`/`Complete`/`Refreshing`; `Promise` per key for single-flight; batched LRU (access queue drained via CAS) | earlier `Cache.scala` read | Med |

**Transfer to cache:** the `Priority`/`Evict` split is a good mental model —
recency/weight = priority (capacity), expiresAt/validity = evict (mandatory).
But the JVM ConcurrentHashMap + CAS-batched-LRU machinery is JVM-specific and
unnecessary for Eta's mostly single-domain cooperative model.

---

## E. Eviction algorithms (Exa + papers, 2026-06-23)

### E1. W-TinyLFU (Caffeine) — High (paper + wiki + commits)

Sources:
- Einziger et al., "TinyLFU: A Highly Efficient Cache Admission Policy", arXiv:1512.00727 (https://arxiv.org/pdf/1512.00727)
- Caffeine wiki "Efficiency" + design commits (https://github.com/ben-manes/caffeine/wiki/Efficiency)

| Claim | Conf |
|---|---|
| Structure: small Window LRU (~1% default, **adaptive** via hill-climber) + main Segmented LRU (probationary → protected, protected up to ~80%) + TinyLFU admission gate | High |
| Frequency tracking: 4-bit Count-Min Sketch with **aging** (periodic halving); ~8 bytes overhead per entry | High |
| Admission: admit a candidate only if its estimated frequency ≥ the victim's frequency; victim sampled from main | High |
| Best-in-class hit rate under skewed/scan/bursty workloads; explicitly **does not retain non-resident (ghost) entries** (unlike ARC/LIRS) | High |
| Cost: multiple deques + sketch + hill-climber → most complex option; tuned for a very large, hot, general-purpose JVM cache | High |

### E2. S3-FIFO (SOSP 2023) — High (paper + repo)

Sources:
- Yang et al., "FIFO Queues Are All You Need for Cache Eviction", SOSP 2023 (https://junchengyang.com/publication/sosp23-s3fifo.pdf)
- https://github.com/Thesys-lab/sosp23-s3fifo ; https://s3fifo.com/

| Claim | Conf |
|---|---|
| Three **static FIFO** queues: S (small, ~10%), M (main, ~90%), G (ghost, metadata-only, size of M) | High |
| **No per-object pointers, no locking on reads/writes** (sequential FIFO); up to ~6× throughput vs optimized LRU at 16 threads | High |
| "Quick demotion": one-hit wonders evicted from S before polluting M; items promoted to M only after a 2nd access | High |
| Lower or competitive miss ratio vs state-of-the-art on 6594 traces / 14 datasets; up to 72% lower miss ratio than LRU reported | High |
| Simple to implement; FIFO order aids flash-friendliness and scalability | High |

### E3. Plain LRU / reinsertion-LRU / CLOCK / ARC — context (Med)

- Plain intrusive doubly-linked LRU: O(1) hit/miss, classic, ~2 pointers/entry. Well understood.
- Reinsertion-LRU (Effect's approach): simplest possible; relies on ordered map; O(1) amortized but reinsertion can cause allocation churn.
- CLOCK / CLOCK-Pro / 2nd-chance: array+reference-bits, low pointer overhead, good for fixed-capacity; ARC/LIRS keep ghost entries (more metadata, non-resident ghosts).
- See Caffeine wiki "Efficiency": W-TinyLFU drops ghosts deliberately (ARC/LIRS retain them).

---

## F. OCaml cache libraries (Exa + opam, 2026-06-23) — Med

None integrate with Eta effects; all are pure data structures (LRU map) lacking
in-flight dedup, failure caching, TTL, and refresh.

| Package | What it is | Eta-relevant gaps |
|---|---|---|
| `lru` (pqwy / D. Kaloper Meršinjak), v0.3.1, ISC | "Scalable LRU caches; weight-bounded finite maps that evict LRU bindings." Functorial over key. https://github.com/pqwy/lru | No TTL, no dedup, no effects, no refresh. Plausible *backing store* only. jsoo status not stated. |
| `janestreet_lru_cache`, v0.17.0 (2024), MIT | LRU map with `max_size`, `find_or_add`, `destruct` hook; used in Iron (production). https://github.com/janestreet/lru_cache | **Depends on `core` + `ppx_jane`** → heavy dependency, wrong ecosystem boundary for `eta`. |
| `lru_cache`, 0.4.0 | Simple LRU, OCaml ≥4.12, examples use Lwt. | No TTL/dedup/effects; Lwt-coupled examples. jsoo status not stated. |
| `containers.CCCache` | `CCCache.lru ~eq ~hash`, `with_cache`/`with_cache_rec` memoization. http://c-cube.github.io/ocaml-containers/ | Pulls in `containers`; memoize-focused, not effect-integrated. |

**Verdict on libraries:** "use a library" reduces to "use an LRU map as the
backing store and wrap it." The cheapest such backing store with no extra
heavy dependency is `Hashtbl` + intrusive linked nodes (or a small in-package
index-array LRU). Pulling `core` (janestreet) or `containers` into an optional
`eta_cache` for just an LRU map is not justified. The whole *value* of an Eta
cache (dedup, failure-as-Exit, per-result TTL, effect-clock, refresh) is not
available from any existing OCaml library, so wrapping buys little.

---

## G. Cross-cutting claims worth recording

1. **Clock portability (Q7):** using `Effect.now`/`Runtime_contract.now_ms`
   keeps the cache testable (override `?now_ms`) and portable to js_of_ocaml.
   Using `Unix.gettimeofday`/`Unix.time` would break jsoo and break tests.
   Eta's own Pool and Effect's Cache both use the runtime clock. **High.**
2. **Locking portability (Q7):** `Sync_lock` (Atomic CAS) is portable and
   already used by Pool/Channel; stdlib `Mutex` needs `threads` and is
   eio/jsoo-unfriendly. Use `Sync_lock`. **High.**
3. **Failure caching semantics differ across references:** Effect caches the
   failure `Exit` until TTL/invalidation (everyone re-fails). zio-cache caches
   failure too **but interruption removes the key** so it can be retried.
   Eta should pick one and document it (recommendation §3). **High.**
4. **Expiry strategy differs:** Pool uses a proactive daemon sweeper; Effect
   uses lazy on-access expiry. Both are defensible; lazy is simpler and
   daemon-free, proactive bounds memory under TTL-heavy churn.
   **High.**
5. **(Revised 2026-06-23.)** Eta *does* have a dual-platform one-shot promise
   via `Runtime_contract` (`create_promise`/`resolve_promise`/`await_promise`,
   implemented by both `eta_eio` and `eta_jsoo`). It is not on the public
   `Effect` surface, but the capability exists and is already proven by
   `.scratch/deferred_pubsub_research`. The remaining seam is whether to expose
   a thin public `Effect.make_promise`/`await`, not whether single-flight is
   possible. **High.**
6. **Platform split is already a `Runtime_contract` seam**, not per-module
   `enabled_if`. `lib/eta` core is backend-neutral; `lib/eio` and `lib/jsoo`
   each implement `Runtime_contract.RUNTIME` (promise, fork, await_cancel,
   yield, now_ms, sleep, stream). The cache should ride the same seam: one
   algorithm authored against the contract, running on both platforms.
   JS genuinely has no mutex/semaphore, but the contract's promise/fork are
   cooperative there, so the cache needs no lock on JS. **High.**
