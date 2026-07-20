# DX-E26 Report — `Effect.fresh`

## Recommendation

**PROMOTE.** The one-pager gate is met. Eta now exposes one runtime-owned
monotonic source through `Effect.fresh` and formats the same source through
`Effect.fresh_named`. Native increments are atomic; jsoo uses a plain mutable
cell owned by each runtime module instance.

`Random`-based DIY is not adequate: random draws do not prove uniqueness, and
using the runtime schedule token for identities couples ID allocation to jitter
and deterministic replay. A caller-owned atomic remains valid when the caller
truly owns a wider, cross-runtime namespace; it is not a substitute for the
runtime-local contract validated here.

## Proof results

| Obligation | Evidence | Result |
| --- | --- | --- |
| Strict monotonicity | `test_fresh_sequence_is_strictly_increasing` | PASS: `[1; 2; 3]` |
| Concurrent uniqueness | `test_fresh_is_unique_under_concurrency` | PASS: 128 concurrent `Effect.all` pulls, 128 unique |
| Test determinism | `test_fresh_replays_across_test_runtimes` | PASS: two fresh test runtimes return the same `[1; 2; 3]` sequence |
| Formatting over one counter | `test_fresh_named_uses_fresh_counter` | PASS: six pulls followed by `fresh_named "worker"` returns `"worker-7"` |
| Native contention | `redteam/contention.md` | PASS: 10,000 pulls, 10,000 unique, 0.958 ms local elapsed |
| Non-global boundary | `redteam/two-runtimes.md` | PASS: two runtimes collide at `1`; `.mli` warns explicitly |
| jsoo behavior | `test_fresh_uses_runtime_local_mutable_counter` | PASS under Node: `[1;2;3]`, then `"worker-4"` |

## Required gates

All commands were run exactly from the worktree and exited 0:

```text
nix develop -c dune build @install                                      PASS
nix develop -c dune runtest --force                                     PASS
nix develop -c eta-oxcaml-test-shipped                                  PASS
nix develop .#mainline -c dune build test/js_jsoo test/cache_jsoo       PASS
```

Additional focused behavior gate:

```text
nix develop .#mainline -c dune runtest test/js_jsoo --force             PASS
```

The known `signal_jsoo` expected failure was not invoked or touched.

## Census and prediction score

| Prediction | Predicted | Actual | Score |
| --- | --- | --- | --- |
| Construct values | +2 | +2: `fresh`, `fresh_named` | 1/1 |
| Concepts | +1 | +1: runtime-owned fresh counter | 1/1 |
| Unresolved footguns | +0 | +0; the per-runtime/global-ID trap is documented and red-teamed | 1/1 |
| Backend shape | native atomic; jsoo mutable cell | exact match | 1/1 |
| Recommendation | promote | promote | 1/1 |

Prediction score: **5/5**.

## Surface and non-goals

The four pre-existing process-global counters remain independent: tracer context
IDs, interrupt IDs, service/typed keys, and runtime IDs have cross-runtime jobs
and were not migrated. No compatibility path or fallback was added. The public
contract explicitly rejects the interpretation that fresh values are globally
unique.
