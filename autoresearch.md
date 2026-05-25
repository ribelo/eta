# Autoresearch: Eta v2 watchlist regression loop

## Objective

Drive Eta's runtime overhead measurably below the v2-ship baseline (commit
`37ab859`) on the four locked watchlist rows, while preserving the
zero-allocation invariants that make v2 viable. The loop compares Eta to
itself only — no Go, no curl, no cross-runtime baselines.

The two structural targets called out in `AUDIT.md`:

1. **`overhead.eta.fail_catch.100k.prebuilt` allocation regression.** v2
   pays ~6× minor words and 242 major words vs v1 for 100k fail/catch
   round trips. Either fix it, or land a representation change that
   recovers most of the gap.
2. **`overhead.eta.pure.reused_rt` warm cost.** v1 was below the timer
   floor; v2 sits around 2 µs. The previous marker-on-record fix was
   rejected because it polluted bind allocation. The acceptance bar
   here is **strict**: any improvement must keep
   `overhead.eta.bind.100k.prebuilt` at zero minor words.

Wins that drop the composite score without violating those invariants are
also welcome.

## Watchlist (locked rows)

| Row                                              | Source bench                  | Direction | Hard invariant                |
|--------------------------------------------------|-------------------------------|-----------|-------------------------------|
| `overhead.eta.bind.100k.prebuilt`                | `bench/runtime_watchlist`     | lower     | minor_words **must be 0**     |
| `overhead.eta.fail_catch.100k.prebuilt`          | `bench/runtime_watchlist`     | lower     | (target: ≤ v1 1,048,573 minor)|
| `overhead.eta.pure.reused_rt`                    | `bench/runtime_watchlist`     | lower     | minor_words **must be 0**     |
| `realuse.retry.flaky.fail4_then_ok`              | `bench/runtime_watchlist`     | lower     | minor_words **must be 0**     |

These rows are mirrored in `bench/runtime_overhead/` and
`bench/runtime_real/` and remain unchanged there. The watchlist bench is
the focused regression bench; the original benches stay as the broader
sanity suite.

## Metrics

The driver script (`autoresearch.sh`) emits METRIC lines parsed by
`run_experiment`.

- **Primary**: `watchlist_score` — lower is better. Composite of the four
  rows normalized against the v2-ship baseline so each row contributes
  ~1.0 at start. A score of 4.0 means "exactly v2 baseline"; 2.0 means
  "halved across the watchlist on average". Wall-time components use
  `min` over samples (more reproducible than `mean` near the timer floor).

- **Secondary** (lower is better unless noted):
  - `fail_catch_minor` — minor words on `overhead.eta.fail_catch.100k.prebuilt`.
  - `fail_catch_major` — major words on the same row.
  - `fail_catch_min_ns` — wall-time floor for fail/catch.
  - `pure_reused_rt_min_ns` — warm pure cost.
  - `bind_min_ns` — bind chain cost.
  - `retry_min_ns` — retry round-trip cost.
  - `bind_minor_invariant`, `pure_minor_invariant`, `retry_minor_invariant`
    — must remain 0; surfaced for dashboard visibility. The official
    enforcement is in `autoresearch.checks.sh`.

## How to run

```
bash autoresearch.sh
```

Internally:
1. `nix develop -c dune build --profile=release bench/runtime_watchlist/runtime_watchlist.exe`
2. Runs the watchlist exe with `--samples 20` and `EIO_BACKEND=posix`.
3. A short Python summariser parses the JSON and prints `METRIC` lines.

Sample count is configurable via `ETA_WATCHLIST_SAMPLES`.

## Regression gate (`autoresearch.checks.sh`)

Runs every iteration before the metric is logged. Hard fail conditions:

- `dune build --profile=release packages/eta/eta.cmxa` fails.
- The soundness gate (`packages/eta/test/soundness/run.sh`) rejects a
  fixture or accepts a negative one.
- `dune runtest --force` fails.
- Any of the three zero-allocation invariants is nonzero.
- Wall-time ceilings are breached (1.5–2× v2-ship baseline):
  - `pure.reused_rt` min wall_ns > 8 000
  - `realuse.retry.flaky` min wall_ns > 80 000
  - `overhead.eta.bind.100k` min wall_ns > 700 000

Tests run on every iteration on purpose: a faster but unsound effect
representation is not a win.

## Files in scope (likely places to change)

- `packages/eta/effect_direct.ml` — public effect record, bind/catch/pure
  wiring, supervisor scope. Both targets live here.
- `packages/eta/runtime.ml`, `runtime_core.ml` — runtime entry, typed-fail
  key generation, frame setup. `fail_catch` cost includes per-iteration
  `Typed_fail.fresh ()` and inner-frame allocation.
- `packages/eta/cause.ml` — `Cause.Fail` round trip on the catch path.
- `packages/eta/exit.ml` — `Exit.Ok` / `Exit.Error` representation.
- `packages/eta/effect.mli` — only widen the public API as a last resort.
- `bench/runtime_watchlist/` — the bench itself. Fine to add per-phase
  METRIC signals but do not weaken the workload (e.g. fewer iterations
  per row) just to bring the score down.

## Off limits

- Do **not** weaken the watchlist (drop a row, lower the iteration count,
  swap `min` for `max` on wall-time, etc.) just to make the metric look
  better.
- Do **not** disable the soundness gate or `dune runtest --force` in
  `autoresearch.checks.sh`.
- Do **not** widen public `.mli` signatures silently.
- Do **not** edit `.backlog/`, `.review/`, `journal.md`, `_build/`.
- Do **not** alter `AUDIT.md`'s recorded baseline numbers; if they need a
  refresh, do it in a separate commit with new measurements.

## Constraints

- `nix develop -c dune build` and `nix develop -c dune runtest --force`
  must keep passing every iteration. The checks script enforces this.
- No new opam dependencies without a clear reason.
- Preserve the Eta boundary called out in `AGENTS.md`: applications own
  state, Eta owns effect description and interpretation.

## What's been tried

### Pre-merge marker fast path (REJECTED, see `AUDIT.md`)

Attempted to add `is_pure` / `is_fail` marker fields to the direct effect
record so `Runtime.run` could shortcut the trivial cases. Recovering
`pure.reused_rt` was easy; the cost was that the compiler kept an
`Effect.pure` allocation inside the bind hot path, regressing
`overhead.eta.bind.100k.prebuilt` from 0 to 1,048,575 minor words per
sample. **The acceptance bar for any new pure/fail fast path is that
`bind.100k.prebuilt` minor_words stays 0.**

## Notes / hints for the next iteration

- The fail_catch allocation regression has two suspects worth profiling
  before guessing:
  1. `Runtime_core.Typed_fail.fresh ()` per `catch` allocates a new key
     (`packages/eta/effect_direct.ml` line ~109). v1 may have batched
     keys differently.
  2. Inner-frame record copy on every `catch` (`{ frame with fail_key; ... }`).
  Run with `--samples 20`, halve the iteration count for one of the two
  to see which dominates.
- `pure.reused_rt` is a single record-allocation + a single `eval ()`
  invocation. The 2 µs is plausibly the `Eio.Fiber.with_binding` round
  trip — measure that path before committing to a representation change.
- Major-words on `fail_catch` (242) is suspicious; it implies Cause
  payloads are escaping the minor heap. Worth a `Gc.minor_words` /
  `Gc.major_words` split if `fail_catch_minor` doesn't move on its own.
