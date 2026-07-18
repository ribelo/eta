# DX-E2 Report — `discard` / `ignore_errors`

## Summary

| Before | After |
|---|---|
| `Effect.ignore` | deleted |
| — | `Effect.discard` |
| `ignore_errors : (unit, _) t -> _` | `ignore_errors : ('a, _) t -> (unit, _) t` |

## Gates

| Command | Result |
|---|---|
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo lib/http_js` | PASS |

Focused: `test/core_eio` 504 tests PASS (`discard`, `ignore_errors`).

## Census / footgun

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Misleading `ignore` val | 1 | 0 | −1 |
| Honest discard transform | 0 | 1 | +1 |
| `ignore_errors` | unit-only | generalized | 0 net val |

**Footgun delta: −1 / +0.**

## Prediction scoring

| Prediction | Actual | Score |
|---|---|---|
| handle −1 + transform +1 | Exact | hit |
| Footguns −1/+0 | Exact | hit |
| 7 ignore uses all tests | Exact; no production sites | hit |
| Hold gate | Not triggered | hit |

## Red-team

Swallowed-error cleanup now requires explicit `ignore_errors` in the diff;
`discard` alone preserves typed failure. **PASS.**

## Recommendation

**Promote.** Breaking; compiler-guided; CHANGELOG extended.
