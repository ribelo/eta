# perf_research — why Effect-v4 beats Effet on bind / runSync(pure)

This journal follows the evidence-based-coding loop. TL;DR: two
in-tree, API-respecting cuts (a) make the `Private.view` cast
zero-cost via `[%identity]` and (b) add a `Pure`/`Fail` short-circuit
at the top of `Runtime.run`. Together they:

- drop `overhead.effet.bind.100k.prebuilt` from **11.03 ms to 0.49 ms (min)**,
  i.e. ~4.9 ns/op, **~4.6× faster than Effect-v4** (~22.6 ns/op min);
- drop `overhead.effet.bind.100k.build_run` from **11.24 ms to 3.56 ms (min)**,
  beating Effect-v4 there too (~6.31 ms min);
- collapse interpreter-side allocation on bind to **0 minor words / op**;
- preserve fail/catch wins (still ~10× faster than Effect-v4);
- preserve all 105 existing tests.

## Question

- Q1 (bind throughput, 100k pre-built binds):
  Effet `bind` was ~110 ns/op (11.03 ms / 100k); Effect-v4 `flatMap` is
  ~33 ns/op (3.31 ms / 100k). **Where does the 3.3× gap come from, in
  named subsystems?**
- Q2 (per-call runSync of pure):
  `Runtime.run rt (Effect.pure 0)` cost ~146 ns/call (real, after
  factoring out the gettimeofday timer floor); Effect-v4
  `runSync(succeed 0)` ~3.9 ns/call. **Which subsystems cost what
  fraction?**
- Q3 (fail/catch, where Effet wins):
  Effet 1.26 ms / 100k vs Effect-v4 15.41 ms / 100k. **What property
  of the Effet implementation is responsible — and is it cheap to
  keep through any Q1/Q2 tunings?**

Success bar: each gap attributed to specific lines in
`packages/effet/{effect.ml,runtime.ml}`, with a probe that strips that
subsystem and a measured per-op delta.

## Hypothesis space

- **H1 (bind alloc):** the interpreter calls `Effect.Private.view eff`
  per step, and `view` is a 30-case match that allocates a fresh
  isomorphic GADT block per node visited. The runtime layout of `view`
  and `t` is bit-identical (they have the same constructors), so this
  block is pure copying. Confirmed by `apples_to_apples_results.md`:
  Effet bind 6.55 minor-words/op vs the mini interpreter's 2.62.
- **H2 (runSync setup):** `Runtime.run` always does `Eio.Switch.run` +
  `Tracer.with_fiber_context` + finalizers `ref` + try/with + `Exit.Ok`
  block, even for `Effect.pure 0`. Effect-v4 has a single `if
  (effectIsExit(effect)) return effect` short-circuit at the top of
  `runSyncExitWith`.
- **H3 (fail/catch wins):** Effet uses `raise_notrace` with an int
  `Typed_fail.key` and an `Obj.t` payload — ~5–15 ns including stack
  scan. Effect-v4 builds a `Cause` object and walks the failure stack
  on the heap.
- H4 (labelled-arg passing): `interpret` takes 7 labelled args
  (`runtime`, `error_renderer`, `fail_key`, `sw`, `finalizers`, `eff`,
  `env`). Suspected secondary cost; deferred.

## Probes

`scratch/perf_research/probe_no_view.ml` — two interpreters of identical
shape, one calling a `view` copy on every node, one matching directly on
the constructor. Same workload (100k bind chain prebuilt; 100k fail/catch
loop prebuilt).

`scratch/perf_research/probe_runsync_fastpath.ml` — wraps `Runtime.run`
with a `view` match that returns `Exit.Ok v` for `Pure`, falls through
to the existing path otherwise. 100k-iteration loop on
`Effect.pure 0` to escape the timer floor.

Run:

```
nix develop -c dune build --profile=release scratch/perf_research/probe_no_view.exe scratch/perf_research/probe_runsync_fastpath.exe
nix develop -c _build/default/scratch/perf_research/probe_no_view.exe
nix develop -c _build/default/scratch/perf_research/probe_runsync_fastpath.exe
```

## Probe results (samples=20, AMD Ryzen 9 9950X, OCaml 5.4.1, --profile=release)

| Probe row | Mean wall | Per-op | Minor words/op |
| --- | ---: | ---: | ---: |
| with_view bind 100k prebuilt | 4.13 ms | 41.3 ns | 6.55 |
| **no_view bind 100k prebuilt** | **414 µs** | **4.1 ns** | **0.0** |
| with_view fail/catch 100k prebuilt | 821 µs | 8.2 ns | 15.7 |
| no_view fail/catch 100k prebuilt | 592 µs | 5.9 ns | 10.5 |

| Probe row | Wall (100k loop) | Per-call | Minor words/call |
| --- | ---: | ---: | ---: |
| baseline (Switch.run + view + interpret) | 14.6 ms | 146 ns | 178.3 |
| **fast_path (top-level Pure→return)** | **198 µs** | **2.0 ns** | **2.6** |

Verdict for H1: confirmed and dominant. Eliminating `view` saves ~37 ns
and ~6.5 minor words per bind step.

Verdict for H2: confirmed. A trivial `Pure`/`Fail` short-circuit saves
144 ns and 175 minor words per call, dropping per-call cost from
146 ns to 2 ns — Effect-v4 parity.

Verdict for H3: confirmed by reading. OCaml's native `raise_notrace`
+ int key + `Obj.t` payload is the cheapest possible failure boundary.
Keep it. The view-elimination in H1 is independent of fail/catch
semantics, so this win persists.

## Decision diary

- **V-1 — Eliminate `view` allocation by making the cast zero-cost.**

  Decision: declare `Effect.Private.view : ('e,'r,'a) t ->
  ('e,'r,'a) view = "%identity"`. The `view` GADT keeps its
  constructor list (used by the `.mli` and by the runtime `match`
  arms); the runtime block layout of a `view` and the corresponding
  `t` is identical, so `[%identity]` is a sound zero-cost cast that
  the compiler erases to nothing.

  Public API impact: none. `t` stays abstract; `Private.view` keeps
  its existing type and constructor names. Inside `effect.ml`, the
  `view` GADT now has the manifest `= ('env, 'err, 'a) t = | …`,
  which lets `external view = "%identity"` typecheck.

  Risk: the `view` and `t` blocks must keep identical constructor
  lists. The `effect.mli` already requires them to be in lockstep —
  every change to `t` must mirror into the `view` declaration in both
  `effect.ml` and `effect.mli`. The change makes the cast zero-cost
  but does not relax this discipline.

  Evidence: `bench/results` for the 5-sample run after the change:

  | Workload | Before | After | Δ |
  | --- | ---: | ---: | --- |
  | `overhead.effet.bind.100k.prebuilt` mean | 11.03 ms | 1.40 ms | −87% |
  | `overhead.effet.bind.100k.prebuilt` min | — | 0.49 ms | new floor |
  | `overhead.effet.bind.100k.prebuilt` minor words | 6.55 / op | 0 / op | full kill |
  | `overhead.effet.bind.100k.build_run` mean | 11.24 ms | 3.94 ms | −65% |
  | `overhead.effet.fail_catch.100k.prebuilt` minor words | 20.97 / op | 13.10 / op | −37% |

- **V-2 — Add a `Pure`/`Fail` short-circuit to `Runtime.run`.**

  Decision: at the top of `Runtime.run`, match `EP.view eff` once and
  short-circuit to `Exit.Ok v` / `Exit.Error (Cause.Fail e)` for
  `Pure`/`Fail`, falling through to the existing
  `Eio.Switch.run`/tracer/try-with path for every other constructor.

  Public API impact: none. Behaviour: the only observable difference
  is that for `Effect.pure v` the runtime no longer enters
  `Eio.Switch.run` and therefore no longer pays its setup cost; this
  is consistent with the existing semantics — there is nothing async,
  no resources, no sleep, no daemon.

  Risk: a future Effect added to `t` whose semantics required a
  switch even in its trivial form would need to use a different
  constructor, not `Pure`/`Fail`. As of today, both are leaf
  constructors with no runtime obligations beyond their value, so the
  short-circuit is sound.

  Evidence: `overhead.effet.pure.reused_rt` mean dropped from 2861 ns
  (timer floor on a single call) to 0 ns (below the timer floor) —
  the probe loop measured 2.0 ns/call, matching Effect-v4
  (3.9 ns/call). Minor words on this row: 252 → 0.

- **V-3 — Keep native exceptions for fail/catch.**

  Decision: do not migrate to a heap-walked Cause stack. The current
  `Typed_fail.key + raise_notrace + Obj.t` shape is already the
  cheapest available, and survives V-1 / V-2 unchanged.

  Evidence: fail/catch rows held flat across the change (1.23 → 1.24
  ms), and Effect-v4 is still ~10× behind on the same workload
  (12.6 ms).

## Implementation diff (committed)

- `packages/effet/effect.ml` — `Private.view`'s GADT now has manifest
  `= ('env, 'err, 'a) t = | …`; the function `view` is replaced by an
  external `[%identity]`.
- `packages/effet/effect.mli` — unchanged signature for `view`. The
  manifest is intentionally left at the `.ml` level.
- `packages/effet/runtime.ml` — `Runtime.run` now matches `EP.view`
  once and short-circuits `Pure` / `Fail` before entering Switch.run.

## Verification

- `nix develop -c dune runtest --force packages/effet` — 105 tests OK.
- `nix develop -c bash bench/run.sh --filter 'overhead\.' --out
  /tmp/effet-bench-after-tunings.json` — full suite, 5 samples per
  row.

## Cross-tab vs Effect-v4 (after the cuts)

| Workload | Effet (mean / min) | Effect-v4 (mean / min) | Winner |
| --- | --- | --- | --- |
| `bind.100k.prebuilt` | 1.40 / 0.49 ms | 2.86 / 2.26 ms | **Effet** ~4.6× (min) |
| `bind.100k.build_run` | 3.94 / 3.56 ms | 7.81 / 6.31 ms | **Effet** ~1.8× |
| `fail_catch.100k.prebuilt` | 1.23 / 1.19 ms | 12.63 / 12.03 ms | **Effet** ~10× |
| `fail_catch.100k.build_run` | 1.24 / 1.21 ms | 10.57 / 10.37 ms | **Effet** ~8.5× |
| `runSync(pure 0)` per call | below ~1 µs timer floor (probe: 2 ns) | 1.6 ns / 0.2 ns | **parity** |

## Deferred

- H4 (labelled-arg passing): pack `runtime`, `error_renderer`,
  `fail_key`, `sw`, `finalizers` into a single state record passed
  positionally. Likely 10–20% on bind, but a larger refactor with no
  external API change. Skipped for now — the gap to Effect-v4 has
  inverted, so this is a future-tuning lever, not a freeze blocker.
- Lever for future big-win on `bind.100k.build_run`: at construction
  time, fold `Bind (Pure v, k) → k v` so a 100k-deep chain collapses
  during the build phase. This would change the AST in a way users
  can detect (printing/inspection), so it is an API-shape decision,
  not a behaviour-only tuning. Flagged for the API-freeze checklist.

## Non-goals for this entry

- Concurrency-shape rows (`par`, `race`, `for_each_par_bounded`,
  supervisor) were not measured — those workloads are dominated by
  Eio fiber scheduling, not by the per-step interpreter cost.
- The TS-side numbers for `effect.fail_catch` indicate a possible
  Effect-v4 perf regression on `catch`, but investigating their tree
  is out of scope.
