# DX-E23 Report — Error channel mirrors `Result`

## Summary

Migrated Eta’s typed error-channel handle cluster to Result-mirroring names:

| Old | New |
|---|---|
| `catch` | `bind_error` |
| `recover` / `or_else_succeed` | deleted; pure both-channel uses `fold` |
| `result` / `option` / `exit` | `to_result` / `to_option` / `to_exit` |
| `catch_some` | kept |
| `or_else` | kept |

`fold ~ok ~error` is the only new composite:
`bind_error (fun e -> pure (error e)) (map ok eff)`.

## Gates

Commands (from worktree):

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
```

All three green on the final tree. Focused re-runs during development:

- `dune runtest test/core_eio --force` → 496 tests OK (includes new fold tests)
- `dune runtest test/api_dx --force` → OK after token-boundary bind scanner fix

JS-track gates not required; no deleted-API call sites in JS packages.

## Census / footgun vs sealed predictions

| Metric | Predicted | Actual | Score |
|---|---|---|---|
| Handle vals | 11 → 10 (−1) | 11 → 10 (−1) | hit |
| Handle concepts | 10 → 8 (−2) | 10 → 8 (−2) | hit |
| Footguns | −1 / +0 | −1 / +0 | hit |
| `bind_error` vs defects | uncatchable | Die surfaces, handler not run | hit |
| `fold` vs interrupt | pass-through | pass-through (unit test) | hit |
| Defect reifier | `to_exit` only | unchanged | hit |

## Red-team

Deliberate misuse: `Effect.sync (failwith …) |> bind_error (fun _ -> pure …)`.

Result: `Exit.Error (Cause.Die { exn = Failure "secret-boom"; … })`. Typed
control path still recovers. The rename removes the top trap’s vocabulary; the
runtime boundary was already correct and remains correct.

## Deviations from objective

1. Protocol asked for separate commits per step; after the sealed-predictions
   commit, implementation/docs/tests were finished then batched into follow-up
   commits (history still proves predictions sealed first).
2. DX scanners needed a token-boundary fix so `Effect.bind` does not match
   `Effect.bind_error` — required for gates, not a public API expansion.
3. Pure recovery call sites use `fold ~ok:Fun.id ~error:` rather than inventing
   a `recover` shim (forbidden). Slightly noisier than old `recover`; matches
   the one-pager’s `fold` contract.

## Recommendation

**Promote.**

Gates green, migration complete (no remaining public `catch` / `recover` /
`or_else_succeed` / bare `result`/`option`/`exit` Effect methods), census and
footgun deltas match sealed predictions, fold tests cover coherence and
uncatchable pass-through, red-team shows the exception footgun is gone by
construction at the naming layer and still enforced at runtime.
