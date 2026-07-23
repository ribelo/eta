# DX-E24c red-team verdicts

Run `redteam/e24c/run-all.sh` after the production deletion is complete.

## A — old source fails loudly

**PASS.** `run-old-style-negative.sh` reuses the canonical
fixtures and verbatim snapshots in `test/type_errors/` rather than duplicating
them under `redteam/`. It requires both a ternary `Schedule.t` annotation and
`Schedule.tap_input` to be rejected, with an arity mismatch and unbound-value
message. A silent erasure or compatibility path fails the probe.

## B — ordinary observation survives

**PASS.** `run-recipe.sh` requires the exact
named integration test `retry attempts can be observed without schedule taps`
and runs the native integration suite containing it. The recipe instruments the
source, so it includes the initial attempt.

## C — laws detect an engine invariant break

**PASS.** Throwaway commit `22d43b25` made the direct engine enter the right
phase on a continuing left decision. The engine compiled, and
`EXPECT_FAILURE=1 run-invariant-law.sh` observed the named `Schedule.and_then`
phase-order law fail and shrink to `(1, 0)`. Revert `f73e45f1` restored the good
engine without changing tests or expectations.

## Runs in this workspace

- `run-old-style-negative.sh`: PASS; canonical compiler snapshots report a
  two-vs-three argument arity error and unbound `Schedule.tap_input`.
- `run-recipe.sh`: PASS; `test/core_eio` ran 566 tests, including the named
  recipe.
- `run-invariant-law.sh`: baseline PASS; 62 generated laws, including the named
  `Schedule.and_then` phase-order property.
- Throwaway corrupted-engine run: PASS; see `INVARIANT_BREAK.md` and
  `invariant-break-output.txt`.
