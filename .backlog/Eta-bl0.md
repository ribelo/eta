---
id: Eta-bl0
title: "P2: Effect.tap_error preserves typed failure when observer raises"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-24T09:05:54.354Z
created_by: backlog
updated_at: 2026-05-24T10:40:53.919Z
close_reason: "Closed by remediation. Added a RED tap_error observer-crash test, changed the runtime to report Suppressed { primary = Fail err; finalizer = observer cause } when the observer raises, documented tap_error observer-raise behavior, and verified the existing non-raising observer regression. Verified with nix develop -c dune runtest --force."
---

# P2: Effect.tap_error preserves typed failure when observer raises

## description

Bug: packages/eta/runtime.ml line ~455 (Tap_error interpreter case) calls observe err inside the with arm of a try/with. If observe err raises, the exception escapes this handler unprotected and propagates up to whichever outer catch translates 'exn -> raise_cause fail_key (cause_of_exn_runtime ...)'. The original Cause.Fail err is replaced by an arbitrary defect from the observer, hiding the typed failure from downstream catch/retry handlers.

Location: packages/eta/runtime.ml Tap_error case (line ~455)

## design

RED test (write first):
1. Build let eff = Effect.tap_error (fun _ -> raise (Failure 'observer crash')) (Effect.fail `My_error).
2. Run via Runtime.run rt eff.
3. Assert the resulting Exit.Error cause carries the original Cause.Fail `My_error somehow combined with the observer defect — for example Cause.Sequential [Fail `My_error; Die _] or Suppressed { primary = Fail `My_error; finalizer = Die _ }.
4. Currently the result is Exit.Error (Die _) — the original typed failure is lost.

Regression check:
- Non-raising observer still passes Cause.Fail err through unchanged.

Fix shape:
- Wrap observe err in a try/with. On observer raise, build a combined cause: Cause.suppressed ~primary:(Cause.Fail err) ~finalizer:(cause_of_exn_runtime runtime fail_key observer_exn) — or sequential, depending on which combinator matches the rest of the cause algebra.
- Document the chosen combinator semantics in tap_error mli.

## acceptance criteria

RED test fails on current code and passes after the fix. Non-raising observer is a regression test that still passes. tap_error mli documents observer-raise behavior.
