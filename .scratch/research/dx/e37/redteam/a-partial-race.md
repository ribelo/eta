# Red team A: completed A, failing B, in-flight C

## Attack

Force two acquisitions to complete in order (`a`, then `b`), then fail a third
only after a fourth has entered a cancellation wait. This attacks direct owner
registration, non-LIFO rollback, and failure return before sibling cleanup.

## Executable assertion

- Test: `acquire_all_par failure reverse cleanup`
- Source: `test/core_common/effect_resource_timeout_common_suites.ml`
- Discriminants: the exit is the acquisition failure; the in-flight acquire
  observes interruption; releases are exactly `["b"; "a"]` before return.

## Outcome

PASS in `nix develop -c dune runtest test/core_eio test/test --force` (626 core
Eio tests and 41 eta_test tests). The staging scope rolls back promptly and the
in-flight child never reaches owner transfer.
