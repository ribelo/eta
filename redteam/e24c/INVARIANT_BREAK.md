# Throwaway schedule-invariant break proof

The attack ran after the E24c production engine and baseline laws were green. It
deliberately corrupted `Schedule.and_then` so the right phase started on a
continuing left decision, skipping the required first-phase output.

- Good implementation commit: `bd272430`.
- Throwaway regression commit: `22d43b25`.
- Command: `EXPECT_FAILURE=1 redteam/e24c/run-invariant-law.sh`.
- Result: the corrupted engine compiled, then `test/laws` failed with the named
  property `Schedule.and_then tags every first phase output before every second
  phase output`, shrinking to `(1, 0)`.
- Revert commit: `f73e45f1`.

No test or expectation changed during the attack. The relevant captured output
is in `invariant-break-output.txt`.
