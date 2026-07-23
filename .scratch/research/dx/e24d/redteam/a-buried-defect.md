# Red-team A — Buried defect is not retried

**Verdict: PASS.**

Named executable: `retry skips composite uncatchable causes` in
`test/core_common/effect_retry_repeat_common_suites.ml`.

The test supplies `Cause.Concurrent [ Cause.Fail `Typed; Cause.Die defect ]`
to `Effect.retry`. It proves all of the boundary, not only the final shape:

- the source runs once;
- neither `while_` nor the schedule policy runs;
- the returned cause is structurally equal to the original composite; and
- the same matrix covers typed failure plus interruption and a suppressed
  finalizer diagnostic.

Thus alignment does not mistake “contains a typed failure” for “catchable.” The
shared boundary refuses the whole composite and the buried defect surfaces.
