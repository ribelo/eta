# eta-cache-research journal

Chronological notes, commands, links, and intermediate decisions.

Worktree: `/home/ribelo/projects/ribelo/ocaml/eta_cache_research`
Objective: `objective.md` (lowercase) in worktree root.
Deliverables dir: `.scratch/research/evidence/eta-cache-research/`

Environment notes:
- Default shell in exec_command is `fish`. Use explicit `bash -c` for scripts.
- Network is available; Exa search used for internet research.
- Reference paths point at the sibling main repo
  `/home/ribelo/projects/ribelo/ocaml/Eta/...` (absolute paths, all resolve).
- Build gate runs through the Nix flake: `nix develop -c ...` (OxCaml 5.2.0+ox
  switch). `eta`/`eta_eio` are installed in that switch (ocamlfind sees them).
- `.scratch` is a *separate* Dune project (`dune-project (name eta_scratch)`).
  After merge, the runnable fixture lives with this evidence under
  `.scratch/research/evidence/eta-cache-research/eta_cache_fixture/`. It is a scratch
  executable, not a public package or root workspace target. Confirmed
  `nix develop -c dune build @install` stays green.

## 2026-06-22 — kickoff

Verified all starting-evidence files exist (porting-candidates.md 775 lines;
effect-smol Cache.ts 1295 lines; Effect.ts + internal/effect.ts; ZIO
Cached.scala + CachedSpec). Plan written.

## 2026-06-23 — evidence pass (read references + internet)

Read directly:
- `porting-candidates.md` §2.14 (single-effect `cached` is the small, separable
  part) and §9 (keyed `Cache` is OUT-OF-SCOPE for core → optional package).
- Effect `Cache.ts`: `MutableHashMap<Key,Entry>` + per-key `Deferred`; single-
  flight; per-result TTL via per-fiber clock; **lazy** expiry (no sweeper);
  eviction = reinsertion-LRU; `refresh` serves old value until new lookup lands;
  `set`/`invalidate`/`has`. Confirmed current vs Effect v4 docs (Exa).
- ZIO `Cached.scala`: single-value `ZIO#cached` (NOT keyed) — analogue of Eta's
  single-effect family, included only to avoid conflating the two.
- zio-cache keyed `Cache` (Exa): lookup function; concurrent single-flight;
  **failure cached, interruption removes the key**; composable Priority/Evict
  policy framework; CacheStats.
- Caffeine W-TinyLFU (Exa + arXiv:1512.00727): window LRU + main SLRU + TinyLFU
  admission (4-bit CountMinSketch, aging); ~8B/entry; best hit-rate, most
  complex.
- S3-FIFO (SOSP 2023): three static FIFOs; no locking; up to 72% lower miss
  vs LRU, 6× throughput; simple; the right "upgrade if hit-rate matters" pick.
- OCaml libs (Exa + opam): `lru` (pqwy, functorial, pure), `janestreet_lru_cache`
  (needs `core`), `lru_cache`, `containers.CCCache`. **None** integrate with
  Eta effects; all are LRU maps lacking dedup/failure-caching/TTL/refresh.
- Eta internals: `pool.mli/ml` (template), `sync_lock.mli`, `effect.mli`,
  `runtime_contract.mli`, `exit.mli`, `cause.mli`, `channel.mli`,
  `semaphore.mli`, `mutable_ref.mli`, `eta_eio.mli`, `eta_jsoo.ml`.

## 2026-06-23 — CORRECTION (the decisive pivot)

**An earlier draft claimed "Eta has NO Promise/Deferred, so single-flight must
be a Semaphore-latch." This was factually wrong** and was caught only by going
to the code (evidence-based-coding skill: settle design questions with the
codebase, not prose).

The truth, read from `runtime_contract.mli`:
- `type 'a promise`, `type 'a resolver`, `create_promise : unit -> 'a promise *
  'a resolver`, `resolve_promise`, `await_promise`. The contract is
  *"intentionally backend-neutral."*
- Both backends implement it: `eta_eio` via `Eio.Promise`; `eta_jsoo` via a
  **custom cooperative promise** (`Pending callbacks | Settled result`,
  `subscribe`, `await ?on_cancel`, microtask/`setTimeout` scheduled).
- `Effect.Expert.contract : context -> Runtime_contract.t` exposes it; **Pool
  already uses it** for shutdown (`create_promise`/`resolve_promise`/
  `await_promise`, pool.ml:45-47,208,561-562,617-618).

Two consequences that rewrite the recommendation:
1. **Single-flight rides an existing dual-platform promise** — not a latch, and
   a new `eta_deferred` is not a prerequisite. Q6 rewritten.
2. **The platform split is already the `Runtime_contract` seam** (not per-module
   `enabled_if`). JS has no mutex/semaphore but the contract's promise/fork are
   cooperative there, so the shared cache code needs no lock on JS. Q5/Q7
   rewritten. The user's "two implementations with shared code" is already the
   architecture of the whole runtime; the cache rides it.

Prior art already on disk: `.scratch/research/evidence/deferred_pubsub_research/runtime_smoke.ml`
builds a `Deferred_probe` over `Eio.Promise` and its alcotest suite passes:
`[OK] first completion wins` (many awaiters share one completion) and
`[OK] failure replays to late awaiter` (failure caching). Native-only probe.

## 2026-06-23 — decision-specific evidence fixture (NEW, runnable)

Following evidence-based-coding, the highest-value proof for the favored design
(Q6 single-flight) is a runnable vertical slice, not prose. Built
`.scratch/research/evidence/eta-cache-research/eta_cache_fixture/` (cache_probe.ml +
runtime_smoke.ml + dune): a minimal keyed-cache prototype proving the *per-key
protocol over a one-shot promise* on Eta's native runtime.

Design of the probe (mirrors the recommendation):
- entry state `Pending of Runtime_contract.promise | Complete of Exit * expires_at_ms`;
- single-flight via `Runtime_contract` promise, obtained through
  `Effect.Expert.contract` (native run exercises the eio backend);
- critical section under `Eta.Sync_lock` (portable CAS), effect-free; user
  `lookup` runs **outside** the lock (Pool two-phase pattern);
- `Effect.exit` turns the lookup's typed failure into `Exit.Error`, so success
  and failure are cached uniformly (the failure-caching-as-Exit property);
- injectable `now_ms` clock (demonstrates the design's testability);
- FIFO oldest-on-overflow eviction (deliberately simplified; LRU hit-path
  allocation is a separate, unproven concern).

Command + result (saved to `fixture_run.out`):
```
$ nix develop -c dune exec --root .scratch ./evidence/eta-cache-research/eta_cache_fixture/runtime_smoke.exe
Testing 'eta_cache_fixture'.
  [OK] single_flight         exactly once under contention.
  [OK] single_flight         hit does not recompute.
  [OK] single_flight         failure cached and replayed.
  [OK] invalidation_and_ttl  invalidate forces recall.
  [OK] invalidation_and_ttl  ttl expiry recalls; ttl 0 never caches.
  [OK] eviction              capacity evicts oldest.
Test Successful in 0.006s. 6 tests run.
```
`nix develop -c dune build @install` stays green (EXIT 0).

What this proves (High confidence, runnable, native):
- single-flight: 8 concurrent `get` of a cold key → lookup runs **exactly once**,
  all 8 receive the same value;
- failure caching: failing lookup runs once, all 6 concurrent getters receive
  the cached `Exit.Error`;
- hit/miss, invalidate-forces-recall, TTL expiry recalls (deterministic clock),
  TTL=0 never caches, capacity evicts oldest.

Honest limits / deferred obligations:
- **NATIVE-ONLY.** The probe routes through `Runtime_contract`, but only on the
  eio backend. The jsoo backend implements the same promise surface, but an
  end-to-end jsoo run remains **unproven**.
- **Lookup-cancellation transition** (a lookup cancelled before completion must
  free the slot so the next `get` retries — the zio-cache interruption rule)
  is **not yet covered** by the fixture. Add it.
- **LRU vs reinsertion allocation** was unmeasured in the first pass; the
  follow-up `alloc_probe.out` now measures reinsertion-LRU at 1556 words/hit
  versus sentinel-intrusive at 2 words/hit.
- The probe caches `Exit.t` directly (uses `Effect.exit`), so it does *not*
  rely on the `result` simplification I considered earlier.

## 2026-06-23 — deliverables status

- `research.md` — source matrix; corrected (the false "no Deferred" claim is
  marked superseded; §A3, §G5–6 rewritten).
- `recommendation.md` — TL;DR, Q5, Q6, Q7, and rejected-#6 rewritten to reflect
  the `Runtime_contract` promise and the platform-split seam; Q6 cites the
  runnable fixture as primary evidence.
- `journal.md` — this file.
- `eta_cache_fixture/` under this evidence directory — runnable native evidence
  (6/6 green).

## What evidence would change the decision

- A jsoo fixture proving the `Runtime_contract` promise path gives
  single-flight on JS (or disproves the no-lock-on-JS claim) would raise Q7
  confidence from Med to High.
- A measurement showing sentinel-intrusive LRU's residual 2 words/hit matters,
  or that reinsertion-LRU is competitive despite its allocation cost, would
  reopen Q4.
- A workload showing a real hit-rate gap vs LRU would justify promoting
  S3-FIFO / W-TinyLFU from "deferred" to "build".

## 2026-06-23 (b) — post-merge continuation: close/downgrade the gaps

Re-confirmed after merge: fixture 6/6 green; `Runtime_contract` promise
surface intact; both backends implement it; `@install` green.

**Upgrade — fixture now routes through `Runtime_contract`.** Rewrote the
fixture's single-flight to use `Effect.Expert.contract` →
`create_promise`/`resolve_promise`/`await_promise` (Pool's recipe), NOT
`Eio.Promise` directly. Still 6/6 on native. This proves the contract surface is
sufficient for the whole protocol → the dual-platform claim now rests on a
*proven* seam, with only the jsoo *backend* run unproven.

Gap verdicts (full detail in `verdict.md`):
- **jsoo path — downgraded (low risk).** Contract sufficiency proven on native;
  jsoo implements the identical promise surface (read). End-to-end jsoo run
  deferred (no jsoo-executable pattern in tree).
- **lookup-cancellation — Unproven.** `Effect.catch` excludes interruption
  (`effect.mli:161`); no `on_interrupt` yet (§2.16). Real correctness gap; must
  resolve before shipping.
- **hot-path allocation — MEASURED (`alloc_probe.out`).** reinsertion-LRU
  **1556 words/hit** vs sentinel-intrusive **2 words/hit** (naive option-pointer
  intrusive = 6). So reinsertion is ~778× worse (direction confirmed), but
  "zero-alloc" is corrected to "~2 words/hit; true zero needs an unboxed find."
- **eviction policy — Reasoned, not measured.** Needs real workloads; declined
  to fake a synthetic Zipf trace (would be flattering, not diagnostic).

Artifacts: `verdict.md` (concise grading), `fixture_run.out`, `alloc_probe.ml` +
`alloc_probe.out`.

**Decision:** recommendation is evidence-backed enough for a v1 *design*
decision. Shipping a real package must first resolve R2 (cancellation) and
ideally R1 (jsoo run); R3/R4 are refinements.
