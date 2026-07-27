# Red team B: late acquire under cancellation

## Attack

Complete `a`, start a finite uninterruptible acquisition, then fail a sibling.
Only after cancellation has been requested is the late acquire allowed to
return `late`. Recover the typed failure inside the same enclosing scope so a
direct-to-owner bug or duplicate registration remains observable.

## Executable assertions

- `acquire_all_par cancellation late completion` proves `late` really completes,
  the success continuation is skipped, rollback is `["late"; "a"]` before
  recovery continues, and enclosing scope exit adds no duplicate release.
- `acquire_all_par late completion census` runs the same shape through
  `Eta_test.Run`, asserts each release once, and requires an available empty
  structured-fiber census.

## Outcome

PASS in `nix develop -c dune runtest test/core_eio test/test --force`. A version
using only a non-scheduling cancellation check left one structured fiber visible
to the root-exit census; the final acquisition-to-staging fence yields after
arming rollback, and the adversarial census is empty.
