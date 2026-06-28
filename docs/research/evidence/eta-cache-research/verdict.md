# verdict — is the eta_cache recommendation evidence-backed enough for v1?

Research verdict, 2026-06-23 (post-merge continuation). This file supersedes
nothing in `recommendation.md`; it grades each major claim and records the
exact evidence, then says what is still unresolved. Companion evidence:
`fixture_run.out` (native contract-routed cache, 6/6), `alloc_probe.out`
(hit-path allocation), and `journal.md` (full diary).

## Re-confirmation after merge (objective 1)

- Native fixture re-run, **6/6 green**:
  `nix develop -c dune exec --root .scratch ./evidence/eta-cache-research/eta_cache_fixture/runtime_smoke.exe`.
- `Runtime_contract` promise surface intact: `create_promise`/`resolve_promise`/`await_promise` + `'a promise`/`'a resolver`, backend-neutral (`runtime_contract.mli:13,16,50-52`).
- `Effect.Expert.contract : context -> Runtime_contract.t` present (`effect.mli:622`).
- Both backends implement the promise: `eta_eio` via `Eio.Promise.create/resolve/await` (`eta_eio.ml:249-251`); `eta_jsoo` via its own cooperative promise `Pending of callbacks | Settled of result` + `await` (suspends via `Effect.perform`, `eta_jsoo.ml:79-80,193-194,249`).
- `nix develop -c dune build @install` **green** (fixture is scratch-only; the gate is unaffected).

**Upgrade since the prior pass:** the fixture was rewritten to route single-flight
through `Runtime_contract` (via `Effect.Expert.contract`, Pool's pattern) instead
of `Eio.Promise` directly. It still passes 6/6 on native. This proves the
*contract surface is sufficient* for the whole protocol — the actual
architectural question behind "dual-platform."

## Claim grading (objective 3)

Legend: **Proven** = runnable/measured evidence; **Reasoned** = sound argument,
no contradicting evidence, but not measured; **Unproven** = open, with a named
risk and a smallest fair probe.

### Design / architecture
| Claim | Grade | Evidence |
|---|---|---|
| Optional `eta_cache` package, not root `eta` | **Reasoned** | Constrained by `objective.md` §9 + `AGENTS.md` package policy; not something a fixture proves. |
| Single-flight via `Runtime_contract` promise (dual-platform) | **Proven (native)** + low jsoo risk | Fixture 6/6 contract-routed; jsoo implements the identical surface (read). |
| Critical section via `Sync_lock`, lookup outside the lock (Pool pattern) | **Proven (native)** | Fixture; `Effect.exit` packs failures; `@install` green. |
| Clock injectability / testability (`Effect.now`/`?now_ms`) | **Proven** | Fixture uses injected `now_ms`; TTL tests deterministic. |

### Semantics
| Claim | Grade | Evidence |
|---|---|---|
| N concurrent `get` cold key → lookup exactly once, all get result | **Proven** | `single_flight.exactly once under contention` (8-way), green. |
| Failure cached as `Exit` and replayed to all getters | **Proven** | `failure cached and replayed` (6 getters all `Exit.Error`), green. |
| Hit/miss, invalidate, per-result TTL, TTL=0 never-caches, capacity eviction | **Proven** | fixture, green. |
| **Lookup-cancellation frees the slot for retry** (zio-cache interruption rule) | **Unproven** | See risk R2. Eta's `Effect.catch` *excludes* interruption (`effect.mli:161`). Eta does expose `on_interrupt` and exit-aware finalizers, but the fixture has not used them to remove a `Pending` entry after cancelled lookup. |

### Performance / eviction
| Claim | Grade | Evidence |
|---|---|---|
| Reinsertion-LRU (Effect's approach) allocates heavily per hit | **Proven** | `alloc_probe.out`: **1548 words/hit** vs **2** for sentinel-intrusive. ~774× worse. |
| Intrusive LRU is "zero-alloc on hit" | **Reasoned (corrected)** | A **sentinel/index** intrusive LRU is **~2 words/hit** (`alloc_probe.out`); the residual is the `Hashtbl.find_opt` option box. A naive `node option`-pointer design is **4 words/hit**. True zero needs an unboxed find (OxCaml index arrays / find-or-default). So: near-zero is proven; *exact* zero is a design choice, not free. |
| LRU (not W-TinyLFU/S3-FIFO) for v1 | **Reasoned, not measured** | See risk R4. No eviction benchmark run; choice rests on cost/complexity/workload-fit, not a measured hit-rate comparison. |

## Exact commands + results (objective 4)

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

$ nix develop -c ocamlopt -O3 alloc_probe.ml -o /tmp/eta-cache-alloc-probe
$ nix develop -c /tmp/eta-cache-alloc-probe
baseline (harness only)       0.000 words/hit
intrusive LRU hit             4.004 words/hit     (node option pointers)
intrusive-sentinel hit        2.000 words/hit     (no option boxes; ~Hashtbl.find_opt)
reinsertion LRU hit        1548.019 words/hit     (Effect's approach)

$ nix develop -c dune build @install          # green (fixture scratch-only)
```

## Unresolved risks (objective 2 — gaps explicitly downgraded)

- **R1 — jsoo end-to-end run (downgraded, low risk).** The contract surface is
  proven sufficient on native, and the jsoo backend implements the identical
  promise ops (read). What is *not* done is compiling+running the fixture under
  `nix develop .#mainline` against `Eta_jsoo` (no jsoo-executable stanza exists
  in the tree). *Smallest fair probe:* add a `(modes js)`/byte+js_of_ocaml
  executable + an `Eta_jsoo` entry, run under mainline, assert the 6 tests.
  *Would change the decision:* only if jsoo's cooperative promise breaks
  concurrent await under its event loop — unlikely given `await` suspends via
  `Effect.perform`, but unproven.
- **R2 — lookup-cancellation (downgraded to Unproven).** Correct cleanup of a
  cancelled in-flight lookup must remove the `Pending` entry so the next `get`
  retries. `catch` excludes interruption, but current Eta has `on_interrupt`
  and exit-aware finalizers; this fixture simply has not proven the cleanup
  path with those APIs. *Would change the decision:* v1 must either prove
  pending-entry cleanup with an interrupt/exit-aware hook, wrap the lookup in
  `Effect.uninterruptible` (changes cancellation semantics), or explicitly
  reject the zio-cache interruption rule. This is a real correctness item, not
  a nicety — it must be resolved before a real `eta_cache` ships.
- **R3 — exact-zero hit-path allocation (downgraded to Reasoned).** Sentinel
  intrusive is ~2 words/hit; true zero needs an unboxed find. Not a blocker for
  v1 (2 words/hit is fine), but the recommendation's "zero-alloc" wording should
  read "~2 words/hit; zero with an unboxed lookup."
- **R4 — eviction policy confidence (Reasoned, not measured).** LRU vs
  W-TinyLFU vs S3-FIFO is a hit-rate question that needs real Eta workloads,
  not a toy synthetic Zipf trace (that would be flattering, not diagnostic).
  *Would change the decision:* if a real workload shows a material hit-rate gap,
  slot S3-FIFO (simple, modern) in behind the eviction seam. Until then LRU is
  the v1 default on cost/complexity grounds, honestly flagged as unevidenced on
  hit-rate.

## Bottom line

The recommendation is **evidence-backed enough to justify a v1 design decision**:
the protocol (single-flight, failure-as-Exit, TTL, eviction) is **proven** on
native via a contract-routed fixture, and the intrusive-vs-reinsertion
allocation claim is **measured**. Two items must be resolved before shipping a
real package: **R2 (lookup-cancellation)** is a genuine correctness gap whose
cleanup path is not yet proven; **R1 (jsoo end-to-end)** is low-risk but
unproven. R3 and R4 are wording/workload refinements, not blockers.
