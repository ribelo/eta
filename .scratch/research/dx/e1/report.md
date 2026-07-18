# DX-E1 Report — `sync_result` / `sync_option`

## Summary

| Before | After |
|---|---|
| Recommended leaf `Effect.sync f \|\> Effect.flatten_result` | `Effect.sync_result f` |
| No sync option leaf | `Effect.sync_option ~if_none f` |
| `flatten_result` required for every typed sync leaf | `flatten_result` kept for hand-rolled pipelines only |

No new semantics: both vals are named compositions of existing primitives.
`Eta_blocking.run_result` symmetry for the non-blocking path.

## Gates

| Command | Result |
|---|---|
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo lib/http_js` | PASS |

## Evidence

| Obligation | Evidence |
|---|---|
| Ok parity with `sync \|\> flatten_result` | `sync_result parity` |
| Error → typed failure parity | `sync_result parity` |
| Exception → Die | `sync_result parity` + red-team |
| Some / None / raise for option leaf | `sync_option parity` |
| Docs recommended leaf re-point | `docs/api-dx.md` preferred shape + preferred API table |
| DX example gate | `test/api_dx` asserts `Effect.sync_result` |

## Census / footgun

Construct cluster **+2 vals / +1 concept**. Footgun **−1 / +0**.

## Red-team

Call `sync_result` expecting typed capture of a raise → still `Die`. **PASS**
(name does not invite attempt-model in executable evidence).

## Recommendation

**Promote.** Additive; gates green; kill gate not fired.
