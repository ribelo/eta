# DX-E1 Journal — `sync_result` / `sync_option`

Branch: `research/dx-e1e2e3-hygiene`
Phase: B (hygiene)

Sealed predictions: `.scratch/research/dx/journal.md` §E1 (commit
`docs(dx-b1): seal predictions`). Not edited after seal.

## Implementation

- `Effect.sync_result` / `Effect.sync_option` added to `effect.mli` +
  `effect_core.ml` as named compositions (`flatten_result (sync f)` /
  `bind (from_option ~if_none) (sync f)`).
- `flatten_result` retained; docs re-point recommended leaf to `sync_result`.
- Parity tests in `test/core_common/effect_common_suites.ml`.
- Recommended-leaf rewrites in `docs/api-dx.md`, `README.md`, `examples/`,
  and `test/api_dx/api_dx_examples.ml` (gate assertions updated).

## Gates

| Command | Result |
|---|---|
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo lib/http_js` | PASS (existing integer-overflow warnings only) |

Focused: `nix develop -c dune runtest test/core_eio --force` — 504 tests PASS
(includes `sync_result parity`, `sync_option parity`).

## Census / footgun actuals

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Construct-cluster public vals | 4 | 6 | +2 |
| Construct-cluster concepts (sync leaf, typed-result leaf, option leaf, named sync-typed leaf) | 3 | 4 | +1 |

**Footgun delta: −1 / +0.** Two-combinator recommended leaf gone from docs;
Die-vs-typed boundary kept explicit in mli (kill gate not triggered by tests).

## Prediction scoring

| Prediction | Actual | Score |
|---|---|---|
| +2 vals / +1 concept | Exact | hit |
| Footguns −1/+0 | Exact | hit |
| Exception → Die (not typed) | Parity + red-team | hit |
| `flatten_result` retained | Yes | hit |
| Kill/rename to `attempt_result` | Not triggered | hit |

## Kill gate

Persona misreading “catches exceptions into typed failure” is disproved by
`sync_result` raise → `Cause.Die`. Name kept.
