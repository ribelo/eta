# Red team C: release failure preserves the primary cause

## Attack

Acquire two resources in a fixed success order and make both releases fail.
Run once after body success and once after typed body failure. This attacks
fail-fast finalization, dropped diagnostics, reversed diagnostics, and cleanup
replacing the primary cause.

## Executable assertion

- Test: `acquire_all_par release diagnostics`
- Source: `test/core_common/effect_resource_timeout_common_suites.ml`
- Success boundary: exit is `Cause.Finalizer (Sequential [failure; failure])`.
- Failed boundary: exit is `Cause.Suppressed` with `Cause.Fail `Body` primary
  and both finalizer failures in sequential release order.
- Both runs assert release attempts `[2; 1]`.

## Outcome

PASS in `nix develop -c dune runtest test/core_eio test/test --force`. Existing
`Runtime_core.with_finalizers` semantics remain authoritative; no release
failure is dropped and the primary body cause remains primary.
