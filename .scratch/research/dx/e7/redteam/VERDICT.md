# DX-E7 Red-team Verdict

## Placeholder attempt

**PASS.** `placeholder_attempt.ml` uses a non-built-in record payload without
`[@eta.render]`. The same fixture is gated in
`test/type_errors/cases/ppx_eta_error_unsupported_payload.ml`; the full compiler
error in `placeholder-error.txt` directs the user to a built-in or explicit
printer. No generated `<payload>` branch exists.

## Raising derived printer

**PASS.** `test_eta_error_raising_renderer_becomes_defect` in
`test/ppx_common/ppx_common_suites.ml` selects a raising custom payload printer
through generated `pp_raising_err`. The Eio-backed runtime returns `Cause.Die
Failure("derived renderer exploded")`; it does not retain `Cause.Fail` and does
not replace the error with a silent fallback. See `raising-renderer.txt`.

## Renamed tag

Baseline commit: `Db_down` renders as `db_down` in `tag_rename.ml` and
`tag-rename-output.txt`. The next red-team commit will rename the source tag and
record the changed output, preserving the telemetry-breaking change in branch
history.

## Verdict

The favored design survived all three attacks: placeholders are impossible,
printer exceptions remain defects, and constructor renames visibly change the
documented telemetry string.
