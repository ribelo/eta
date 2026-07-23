# Throwaway schedule-invariant break proof

This attack must run only after the E24c production engine and baseline laws are
green. It deliberately corrupts `Schedule.and_then` ordering and proves that the
named generated law detects the regression.

1. Copy the repository to a disposable directory outside this worktree (exclude
   `_build*` and `_opam`). Do not perform the attack in the delivery worktree.
2. In the copy, run `redteam/e24c/run-invariant-law.sh`; it must pass.
3. In the copy's `lib/eta/schedule.ml`, change the direct `and_then` engine so a
   second-phase output is published before a first-phase output (or equivalently
   swap the phase order). Do not change any test or expectation.
4. Run `EXPECT_FAILURE=1 redteam/e24c/run-invariant-law.sh`.
5. Preserve the failing output in the review evidence before deleting the copy.

Acceptance: the command exits zero only because `test/laws` failed and its output
names `Schedule.and_then tags every first phase output before every second phase
output`. A compile failure is not evidence; the corrupted engine must compile.
