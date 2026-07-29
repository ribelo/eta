# Follow-up 3: DX-E41 — review findings: prove loop-stoppage, fix false docs, tighten law rows

Independent PR review verdict: should-not-merge. The **implementation** was
upheld as structurally sound (shared `with_auto_impl`, no leak path,
`with_supervised_background` cancels+awaits, `with_random` reaches the loop
via `Effect.repeat`). The defects are in tests, docs, and registry
precision. All four findings were independently verified by the
orchestrator before this follow-up. Fix all four; nothing here should need
implementation changes — if a new discrimination test FAILS against the
current implementation, that is a real bug: stop and report it raw.

## F1 — The exit matrix does not prove the loop stops (R170)

Every scope-exit test uses `Schedule.recurs 1`
(`test/core_common/resource_common_suites.ml:486,502,527,549,588,605`;
census test `test/cache/test_eta_cache.ml:324`). Once the blocked second
load is interrupted, that schedule is *naturally exhausted* — a broken
coordinator that cancels the in-flight refresh but lets the loop resume
would still terminate with exactly two calls and an empty census. The
held-finalizer test proves in-flight cancellation; nothing proves the loop
cannot resume.

**Fix:** re-run the exit matrix and the census test against a schedule
that cannot exhaust naturally (`Schedule.forever`, or `recurs` with ≥2
remaining recurrences), with a third-load trap: after body exit (each of
the four kinds), advance the clock well past the next scheduled tick and
assert no further load ever ran. Keep the existing in-flight finalizer
test — it covers a different clause of R170.

## F2 — OTel docs describe code that does not exist

`docs/tutorial-eta-otel.md:111-123` shows `Eta_cache.Refreshable.manual`
loading the exporter configuration; `lib/otel/README.md:155-160` says the
daemon loads cached configuration through `Eta_cache.Refreshable`.
`lib/otel/eta_otel.ml:716-738` uses a plain immutable record; `eta_otel`
has no `eta_cache` dependency (correctly). Check what these docs said
before your branch — if they already claimed a resource-backed config
(under the old name), the falsehood predates you; either way this branch
ships false documentation.

**Fix:** document the actual architecture (immutable configuration value,
no ambient channel). No invented Refreshable linkage.

## F3 — R167 and R175 overclaim their evidence

- **R167 "manual loads once":** the registered test's loader
  (`resource_common_suites.ml:148-163`) reads a ref; two seed calls would
  return the same value and pass. Add an exact call counter and assert
  exactly one seed load.
- **R175 "typed failure recorded BEFORE on_refresh_error runs":** current
  tests inspect the final ledger after the callback. A callback-first
  implementation would pass them. Add a barrier test: block inside
  `on_refresh_error` (promise), observe `failures` while the callback is
  still running, assert the typed failure is already recorded.
- **Registry disposition:** the removed-claim entry says R167–R175 but the
  random law is R176 — fix the range (`.scratch/research/dx/e22/review/LAWS.md:377`).

## F4 — Example and DX-guide wording

- `examples/cached_resource.ml` defines the canonical `with_auto` form
  first but its main runs only `program_with_alerts` (line 67). Examples
  are executable API evidence: run the canonical program (or both forms),
  and say which is canonical in the output.
- `docs/api-dx.md:335-336` still says "runtime-owned resource failure
  diagnostics" — contradicting lexical ownership. Fix the vocabulary.

## Required

1. Fixes F1–F4 with the same evidence discipline as the original delivery
   (named tests, exact spans in the registry).
2. Journal: new section scoring the review's findings (which were
   justified, which weren't) — honesty over defensiveness; the R170 hole
   is a test-design miss the predictions should have caught.
3. Report: append `Follow-up 3 outcome`.
4. Full four-gate quartet.

## Done means

`E41 READY FOR REVIEW` (or `E41 BLOCKED: <reason>` — e.g., if F1's new
tests fail against the current implementation, BLOCKED with the failing
output). Same scope fence. This file stays uncommitted.
