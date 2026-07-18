# DX-E3 Report — `race_either`

## Summary

| Before | After |
|---|---|
| Heterogeneous race via map-wrapping both branches | `Effect.race_either left right` |
| Uniform `race` only | `race` retained for homogeneous lists |

## Gates

| Command | Result |
|---|---|
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo lib/http_js` | PASS |

Focused: `test/core_eio` 508 tests PASS.

## Evidence

| Obligation | Evidence |
|---|---|
| Left winner + loser cancel | `race_either left winner cancels loser` |
| Right winner (finish order ≠ argument order) | `race_either right winner` |
| Scoped loser resource release | `race_either releases scoped loser resource` |
| Finalizer diagnostic parity with race | `race_either finalizer parity` |

## Census / footgun

Concurrency race family **+1 val / +1 concept**. Footgun **+0**.

## Prediction scoring

| Prediction | Actual | Score |
|---|---|---|
| +1 val / +1 concept | Exact | hit |
| Footguns +0 | Exact | hit |
| Same cancel/resource semantics as race | Tests | hit |
| Kill if Left/Right harder than named variants | No review hold evidence in-executor; tags positional and documented | hit (no kill) |

## Red-team

Map-wrapped workaround vs `race_either`: workaround still clearer only when
call-site domain variants already exist; for timeout-vs-result the either tags
are shorter. Nothing material remains clearer about the workaround for the
stated heterogeneous race. **PASS promote.**

## Recommendation

**Promote.**
