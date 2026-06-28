# recommendation.md — eta keyed cache

Final recommendation for a future Eta keyed cache, produced from the evidence
in `research.md` and the journal. Answers the 8 questions in `objective.md`.
This is design research, **not** an implementation; nothing here is wired into
the build.

## TL;DR

**Build a small keyed cache from scratch as an optional `eta_cache` package.**
Do not use an external OCaml library as the cache itself, and do not put it in
root `eta`. Justification in three lines:

1. The entire *value* of an Eta cache over `Hashtbl` is **effect-integrated**:
   in-flight dedup (one lookup per key under contention), failure cached as
   `Exit`, per-result TTL from the runtime clock, manual refresh, stats. **No
   existing OCaml library provides any of this** (research.md §F).
2. Eta already ships the exact building blocks — `Sync_lock`, `Semaphore`,
   `Channel`, `Mutable_ref`, `Effect.now`, `Effect.daemon`, `Exit`, `Duration`,
   and **a backend-neutral one-shot promise in `Runtime_contract`**
   (`create_promise`/`resolve_promise`/`await_promise`, implemented by both
   `eta_eio` and `eta_jsoo`) — and a near-template (`Pool`) that solves
   capacity + TTL + waiters + stats. A prior scratch lab
   (`.scratch/deferred_pubsub_research`) already proved exactly-once completion
   and failure replay on the promise primitive. The cache is mostly a
   generalization of Pool (research.md §A1).
3. The only real seam is that the promise is not on the public `Effect`
   surface — so the design must decide whether `eta_cache` (a) rides the
   `Runtime_contract` promise internally via `Effect.Expert`, or (b) a thin
   public `Effect.make_promise`/`await` is added first. Either way the
   per-key single-flight maps directly onto an existing, dual-platform
   primitive (research.md §A3, §G5–6).

Start with **plain LRU + lazy on-access expiry + per-result TTL + in-flight
dedup + failure-as-Exit + stats**. Keep W-TinyLFU / S3-FIFO as a documented
future extension behind the eviction seam, not v1.

---

## Q1 — What problem does an Eta keyed cache solve beyond single-effect `cached` and `Hashtbl`?

- **vs `Hashtbl`:** `Hashtbl` is an unbounded mutable map with no capacity, no
  eviction, no TTL, no expiry, and no concurrency story. It does not dedup
  concurrent lookups, does not cache failures, and leaks memory under unbounded
  key growth. A keyed cache adds: bounded capacity with eviction, TTL/expiry,
  **single-flight lookup sharing**, and typed-failure caching.
- **vs single-effect `cached`/`memoize` (objective §2.14, adopted separately):**
  that family caches **one** effect's result (one key, implicitly "the value").
  A keyed cache keys over **arbitrary user keys**, dedups per key, and bounds
  total memory across many keys. They are different layers: single-effect
  `cached` is a degenerate keyed cache with one key; the keyed cache is the
  generalization. They should share **nothing** in code yet (the single-effect
  one is a latch+cell; the keyed one is a capacity-bound map), but they share
  the *single-flight protocol*.
- **Concrete user problems solved:** dedup a burst of identical expensive
  lookups (e.g. the same user/config/feature-flag id in flight across many
  request fibers) so the work runs once; bound memory across a large key space
  with LRU eviction; give entries a per-result TTL (cache a "not found" for a
  short time but a success for longer); refresh in the background; expose
  hit/miss/eviction stats.

**Confidence: High.** This is the standard justification and matches
effect-smol/zio-cache motivation (research.md §B, §D).

---

## Q2 — Public shape: functor, record of key ops, polymorphic hashing, or multiple?

**Recommendation: a first-class module/functor over `hash` and `equal`, plus a
polymorphic-default convenience constructor.** Optimize for OCaml idiom and
performance, not TypeScript generics.

- A functor `Cache.Make(Key : Hashtbl.HashedType)` gives the fast specialized
  path (specialized `hash`/`equal`, monomorphic value type, lets OxCaml unbox
  and inline). This is the idiomatic OCaml answer and matches how `Hashtbl.Make`
  and `Map.Make` work; it is what users reach for.
- A default module `Cache.Poly` (polymorphic `Hashtbl.hash`/`(=)`) covers the
  "just give me a cache" case at the cost of polymorphic comparison. This
  mirrors `Hashtbl` vs `Hashtbl.Make`.

Why not a record-of-functions `{ hash; equal }`? It works but blocks
specialization: the key operations stay first-class closures, so the hot path
is an indirect call every `get`. For a cache whose entire point is speed, the
functor (or a `[@@inline]` record at minimum) is better. Recommend functor as
primary; the record form can be the internal representation the functor fills
in, but the public, specialized surface is the functor.

Do **not** expose multiple competing key APIs; one functor + one Poly default.

**Confidence: Med-High.** Idiomatic and matches stdlib precedent; the only
tension is OxCaml mode/specialization details, which a prototype should
confirm (benchmark plan, Q8).

---

## Q3 — Semantics (match ZIO/Effect)

Adopt the union that best fits Eta. Concretely:

| Feature | Decision | Rationale / reference |
|---|---|---|
| In-flight dedup | **Yes.** Concurrent `get(k)` during an in-flight lookup share one computation; waiters receive the same result. | Effect §B, zio-cache §D, Pool §A1 (waiters) |
| Failure caching | **Yes, as `Exit`.** A failed lookup's `Exit` is cached for its TTL, so all waiters and immediate retries receive the same failure rather than re-running the failing work. | Effect §B (`onExit` completes deferred with the failure too) |
| Interruption | **Interruption of the *lookup* removes the key** so the next `get` retries (do not strand a permanent failure). Waiters cancelled while waiting just leave the waiter set (Pool's `cancelled_waiters` accounting). | zio-cache §D ("interruption removes the key"); aligns with Eta cancellation |
| TTL | **Per-result**, `time_to_live : Exit.t -> key -> Duration.t` (not a single global number). Default: a constant TTL for all exits. | Effect §B `timeToLive(exit,key)`; enables "fail short, succeed long" |
| TTL = 0 | Remove the entry (never cache). | Effect §B |
| Expiry | **Lazy, on-access** (checked in `get`/`contains`/`get_if_present`), like Effect. An **optional** `Effect.daemon` sweeper can be enabled for TTL-heavy churn to bound memory; default off. | Effect §B (lazy); Pool §A1 (daemon) as the optional alternative |
| Refresh | `refresh k` always re-runs lookup and updates the entry; **concurrent `get` callers during refresh see the still-valid old value** until the refresh completes. | Effect §B `refresh`; zio-cache §D `refresh` |
| get-if-present | **Yes:** `get_if_present k` returns the cached `Exit` without invoking lookup (None if absent/expired). | Effect `getOption`/`has` |
| set (manual populate) | **Yes:** `set k v` inserts a pre-resolved success. | Effect §B `set` |
| invalidate | `invalidate k`, `invalidate_all`, and an optional `invalidate_when (Exit -> bool)`. | Effect §B; zio-cache §D |
| Capacity | **Bounded**; when full, evict per the policy (Q4). `Infinity` allowed = unbounded map (only TTL, no eviction). | Effect §B |
| Stats | `hits, misses, loads, load_failures, evictions, expired, size` snapshot under lock. | zio-cache §D; Pool §A1 |

**Failure-caching nuance (pick one, document it):** Effect keeps a cached
failure until TTL/invalidation. zio-cache additionally drops the key on
*interruption*. Recommend the **zio-cache rule for interruption only**: a
lookup that completes with an error is cached for its TTL; a lookup that is
**cancelled** (interrupted) frees the slot so the next caller retries. This is
the least surprising behavior under Eta cancellation and avoids permanently
caching "this key failed because *we* cancelled."

**Confidence: High** on the feature set; **Med** on the interruption/failure
distinction until a prototype proves the waiter-cancellation path is clean.

---

## Q4 — Eviction algorithm

**Recommendation: plain intrusive LRU for v1.** Document W-TinyLFU and S3-FIFO
as future options behind an explicit eviction seam. Reasoning:

- **Cost model:** Eta's target is a *runtime-owned* cache (dedup + TTL + single
  flight), typically modest capacity (10²–10⁴ entries) on mostly-cooperative
  single-domain access. Hit-rate optimality (W-TinyLFU) matters most for very
  large, hot, general-purpose caches (Caffeine's target). For Eta's scale, the
  practical default should be the simpler policy unless a benchmark shows a
  meaningful miss-rate gap. This research did **not** measure an Eta-specific
  "LRU is within a few percent" bound.
- **Allocation/overhead:** intrusive doubly-linked LRU is O(1) hit/miss with
  ~2 pointers/entry and avoids remove+insert churn on hits. Effect's
  reinsertion-LRU (remove+re-insert into an ordered map on every hit) is
  simplest to write but measured badly in the local allocation probe:
  1548 words/hit vs 2 words/hit for sentinel-intrusive. Prefer intrusive nodes
  if the objective is a deliberately low-allocation hit path.
- **Complexity:** W-TinyLFU needs a Count-Min sketch (4-bit, aging) + window +
  probationary/protected SLRU + a hill-climber (research.md §E1). S3-FIFO is
  simpler (three static FIFOs, no per-object pointers) and is the right
  "upgrade if hit rate matters" choice (research.md §E2). Neither is justified
  for v1 without a measured hit-rate gap.
- **Future-proofing:** define the cache around a small **eviction policy
  interface** (e.g. `on_access`, `on_insert`, `victim : unit -> key option`,
  `remove`) so LRU, S3-FIFO, or W-TinyLFU can slot in later without changing
  the public API. This is the single most valuable design move for Q4.

Rejected: CLOCK/2nd-chance (array+ref-bits; reasonable but no advantage over
intrusive LRU at Eta's scale and less idiomatic in OCaml); ARC/LIRS (ghost
entries add metadata; W-TinyLFU explicitly avoids them).

**Confidence: Med-High** on "LRU now, seam for later" as a scope/complexity
recommendation; **Low** on any precise hit-rate delta until an Eta benchmark
exists. Whether S3-FIFO will ever be needed depends on real workloads — that's
what benchmarks test.

---

## Q5 — Backing data structure (native + js_of_ocaml)

**Recommendation: `Hashtbl` (functor-specialized) + intrusive doubly-linked
list for LRU order.** Per-entry record holds the LRU node pointers, the entry
state, `expires_at_ms`, and the waiter set.

- `Hashtbl.Make(Key)` (or the in-package equivalent) for O(1) key→entry lookup
  with a user-supplied `hash`/`equal`. Portable native + jsoo; no C stubs; no
  `threads`.
- Intrusive doubly-linked list (head = most-recent, tail = least-recent) for
  O(1) `move_to_head` on hit and `pop_tail` on eviction. Intrusive = the LRU
  pointers live **inside** the entry record, so no extra node allocation per
  access — this is what keeps the hit path low-allocation (cf. Q4).
- Entry record (sketch):
  ```
  type entry_status = Pending | Complete of ('a,'e) Exit.t | Refreshing
  type entry = {
    mutable prev : entry;          (* intrusive LRU *)
    mutable next : entry;
    mutable status : entry_status; (* single-flight state *)
    mutable expires_at_ms : int;   (* 0 / absent = never expires *)
    waiters : waiter_list;         (* see Q6 *)
  }
  ```
- Expiry: lazy on access (compare `Effect.now` to `expires_at_ms`). If the
  optional sweeper is enabled, it walks the LRU tail under lock and evicts
  expired entries (Pool's `take_expired_idle_locked` pattern, §A1).
- **Avoid:** index-array designs (cache-friendly but capacity-fixed and harder
  to grow/shrink, less idiomatic); separate timing wheel for TTL (only worth it
  with millions of TTLs expiring precisely; lazy + occasional sweep suffices).

**js_of_ocaml viability:** the whole structure is plain OCaml records, mutable
fields, and `Hashtbl`. No `Unix`, no `Mutex`/`threads`, no C stubs, no
unboxed-int tricks that jsoo can't lower. The clock comes from `Effect.now`
(runtime-supplied, jsoo-safe). The lock is `Sync_lock` (Atomic, jsoo-safe).
This is the same portability profile as Pool. **Verify with the jsoo benchmark
(Q8).**

**Confidence: High.**

---

## Q6 — Concurrency with Eta effects

**This section was revised on 2026-06-23.** An earlier draft claimed "Eta has
no `Deferred`/`Promise`, so single-flight must be a `Semaphore`-latch." That was
**factually wrong**: `Runtime_contract` exposes a backend-neutral one-shot
promise (`create_promise`/`resolve_promise`/`await_promise`) implemented on
both the eio (native) and jsoo backends, and `.scratch/deferred_pubsub_research`
already proved exactly-once completion + failure replay on it (research.md §A3,
§G5). The latch framing is retained below only as a *rejected* alternative.

**Recommended single-flight primitive: a per-key `Runtime_contract` promise**, a
direct map of Effect's per-key `Deferred` and zio-cache's per-key `Promise`.
This is the natural design and it is already dual-platform.

**Single-flight protocol:**

1. `get k`:
   - Look up the entry (under `Sync_lock` on native; no lock on JS, see Q7).
   - **Hit (Complete, not expired):** move to LRU head, return the cached `Exit`
     (Ok or the cached Error).
   - **In-flight (Pending):** the entry already holds a `('a,'e) Exit.t promise`;
     `await` it and return its result. **No duplicate computation.**
   - **Miss:** under the lock, create the entry in `Pending`, allocate its
     `promise`/`resolver` via `create_promise`, insert + move to head + enforce
     capacity (evict tail). Release the lock. Run the user `lookup k` **outside**
     the lock. Then under the lock: write the resulting `Exit` into the entry,
     compute `time_to_live exit k`, set `expires_at_ms` via `Effect.now`, move to
     `Complete`, `resolve_promise` the promise with the `Exit`. Release.
2. **No duplicate computation on a miss** is guaranteed by Pending + promise: the
   first miss runs the lookup; every later concurrent getter finds Pending and
   `await`s the same promise. **Proven (native, runnable):** `eta_cache_fixture`
   `single_flight.exactly once under contention` — 8 concurrent `get` of a cold
   key ran the lookup exactly once and all 8 received the same value
   (research.md §A3; `fixture_run.out`).
3. **Failure caching** falls out for free: `resolve_promise` with `Exit.Error`
   means every awaiter — and the next getter within the TTL window — receives
   the cached failure. **Proven (native):** `eta_cache_fixture`
   `failure cached and replayed` — a failing lookup ran once and all 6
   concurrent getters received the cached `Exit.Error` (`fixture_run.out`).
4. **Cancellation:** the contract's promise `await` participates in runtime
   cancellation (`await_promise` honors cancel on both backends). A waiter
cancelled while waiting just leaves (no `Mutex`/slot leak on JS; semaphore
accounting on native if a `Semaphore` is used for capacity gating). A lookup
**cancelled before completion** must transition the entry out of Pending and
free the slot so the next `get` retries (Q3 interruption rule). *This
lookup-cancellation transition is the one part of the protocol NOT yet covered
by `eta_cache_fixture` — it is the highest-value fixture extension (Q8 #6).*
5. **Refresh:** `refresh k` allocates a fresh promise, runs a fresh lookup,
   and resolves the *new* promise; the old entry stays Complete and serves
   `get` callers until the new lookup resolves and replaces it (Effect §B).

**The promise lives behind `Effect.Expert.contract`** today. Two options, both
in scope (the user confirmed adding a small promise surface is fine):

- **(P) Ride the contract internally** — `eta_cache` authors single-flight
  through `Effect.Expert.contract`. No new public primitive. Cost: the cache
  depends on `Expert`, like Pool already does (`pool.ml:435-436`).
- **(Q) Add a thin public `Effect.make_promise`/`await`** — a small, typed,
  one-shot surface over the contract promise (essentially promote
  `Deferred_probe` to a public module). Cost: a new public API; benefit:
  single-effect `cached`/`memoize` (objective §2.14) and any future
  user single-flight share it.

**Recommendation: start with (P) (Expert, like Pool); promote to (Q) only if
single-effect `cached` or a third caller needs it.** Do not add `eta_deferred`
speculatively (research.md §A3 shows the capability already exists in the
contract; a public wrapper is a separate, evidence-triggered decision).

**Rejected alternative: `Semaphore`-latch + `Mutable_ref`.** It works (it is
Pool's waiter pattern) and it is worth keeping in the lab as a backstop, but it
reimplements one-shot completion that the contract promise already provides,
duplicating a dual-platform primitive. Use it only if a measurement shows the
contract promise's cancellation accounting is insufficient — which the
single-flight fixture (Q8 #6) is designed to surface.

---

## Q7 — Runtime and package boundaries (OxCaml and js_of_ocaml)

**Package boundary:** optional package **`eta_cache`** → public library
`eta_cache` → top-level module `Eta_cache`. Follows the least-astonishment
rule (opam name = dune lib = module). Depends on `eta` only. **Not** root
`eta`. (research.md §A4; objective non-goals.)

**Runtime boundaries:**

- **Must be portable:** use `Effect.now`/`Runtime_contract.now_ms` for the
  clock (jsoo-safe, testable), `Sync_lock` for mutation (jsoo-safe Atomic),
  `Semaphore`/`Channel` for waiters (jsoo-safe cooperative). No `Unix`, no
  `Mutex`/`threads`, no C stubs, no Sys.opaque_identity tricks. This is the
  Pool portability profile (§A1).
- **Native-only optimizations to isolate (do NOT bake into the public path):**
  - OxCaml `[@@unboxed]`/`[@@local_allocate]` for hot entry records, or flambda
    specialization of the functor's `hash`/`equal` — keep these behind
    `enabled_if`/mode fences so jsoo builds unchanged.
  - Any `Atomic` int-as-bitfield packing for entry status — only if a benchmark
    shows it matters; otherwise plain variants.
- **js_of_ocaml gate:** the package's `dune` stanza must build under
  `nix develop .#mainline` and a minimal jsoo test (create, get hit/miss, TTL
  expiry via a fake `?now_ms`, refresh, invalidate) must pass. Do **not** report
  OxCaml `nix develop` success as JS evidence (objective is explicit).

**Confidence: High** (mirrors existing Pool/Channel portability).

---

## Q8 — Benchmark plan

Prototypes live under a **separate scratch Dune project** (`.scratch/...`,
not wired into the root workspace — objective). Verify native via
`nix develop -c ...`, jsoo via `nix develop .#mainline -c ...`.

Scenarios (each reports throughput, allocs/op via `statmemprof`/counters, and
hit-rate where meaningful):

1. **Pure hit** — pre-populate to capacity, read same keys. Validates LRU
   `move_to_head` cost and allocation-per-hit. *Goal: near-zero allocation per
   hit; true zero needs an unboxed lookup.*
2. **Pure miss** — new keys each time. Validates insert + eviction + lookup-run
   path and waiter setup.
3. **Mixed hit/miss** — Zipf-ish key distribution at several capacities.
   Validates overall throughput and the LRU hit curve.
4. **Eviction-heavy** — capacity << key space, scan/bursty access. *This is the
   test that would justify S3-FIFO/W-TinyLFU later*; capture the LRU hit-rate
   baseline now.
5. **TTL expiry** — entries expire; with lazy-only vs lazy+sweeper. Validates
   expiry check cost and the sweeper's memory-bounding claim. Use a fake
   `?now_ms` clock for determinism.
6. **Concurrent same-key** — N fibers `get` the same cold key at once; assert
   the lookup ran **exactly once**; measure waiter wake-up latency. *Status:
   exactly-once is **proven (native)** by `eta_cache_fixture`; wake-up latency
   and the lookup-cancellation transition remain to measure/add.* Validates Q6
   single-flight + the runtime-contract promise.
7. **Concurrent many-key** — N fibers across many keys under contention;
   measure contention on the single `Sync_lock` (decide if a sharded lock is
   ever needed).
8. **Native allocation** — `statmemprof`/a custom counter on the hot path to
   confirm "low allocation" (objective). Current evidence shows
   sentinel-intrusive at ~2 words/hit; true zero requires an unboxed lookup.
9. **js_of_ocaml viability** — build + run a minimal scenario (1–7 minus heavy
   concurrency) under `nix develop .#mainline`. Confirms portability (Q7).

Baseline comparators: a hand-rolled `Hashtbl`+lock (shows the dedup/TTL value),
and, optionally, `pqwy/lru` as a backing-store-only reference (shows the cost of
"just use a library").

**Confidence: High** (plan is concrete and maps 1:1 to the design decisions).

---

## Rejected alternatives (recorded so they're not re-litigated)

1. **Skip the cache entirely.** Rejected: dedup + per-result TTL + failure
   caching is genuinely useful and awkward to build by hand (objective §2.14
   makes the single-flight point; the keyed version compounds it). Pool already
   proves Eta benefits from owning this kind of structure.
2. **Put it in root `eta`.** Rejected by objective §9 / non-goals and
   `AGENTS.md` package policy: it's a heavier subsystem → optional package.
3. **Wrap an external OCaml LRU library as the cache.** Rejected as the
   *cache*: none offer dedup/failure-caching/TTL/refresh/effect-clock, so the
   wrapping *is* the implementation (research.md §F). A pure-LRU lib is at most
   a candidate backing store, and `Hashtbl`+intrusive nodes is cheaper and
   dependency-free.
4. **Ship W-TinyLFU / S3-FIFO in v1.** Rejected for v1: complexity not
   justified at Eta's scale without a measured hit-rate gap. Kept as a future
   option behind the eviction seam (Q4).
5. **Use reinsertion-LRU (Effect's approach).** Rejected for v1: remove+re-
   insert is simple, but the local allocation probe measured 1548 words/hit
   versus 2 words/hit for sentinel-intrusive. Prefer intrusive nodes (Q4/Q5).
6. **Add a `Deferred`/`Promise` to root `eta` to match Effect/zio-cache.**
   Rejected as *speculative*: the `Runtime_contract` already provides a
   dual-platform one-shot promise (research.md §A3), and
   `.scratch/deferred_pubsub_research` proved single-flight on it. The cache
   rides the contract promise via `Effect.Expert` (Q6). A *public*
   `Effect.make_promise`/`await` is a separate, evidence-triggered decision
   (promote it only when single-effect `cached` or a third caller needs it), not
   a prerequisite for the cache. (Note: a `Semaphore`-latch is likewise
   rejected as the primary mechanism — it duplicates a primitive the contract
   already provides — but kept as a lab backstop, Q6.)
7. **Proactive sweeper as the only expiry strategy.** Rejected as the default:
   lazy on-access is simpler and daemon-free; the sweeper is an *optional*
   memory-bounding knob for TTL-heavy churn (Q3).
