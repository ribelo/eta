---
id: Eta-zfn
title: "P2: retry_eff catch-all must use cause_of_exn_runtime"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-24T09:06:05.293Z
created_by: backlog
updated_at: 2026-05-24T10:42:35.365Z
close_reason: "Closed by remediation. Added a RED retry test for Eio.Exn.Multiple, changed retry_eff's catch-all from die_of_exn_runtime to cause_of_exn_runtime with the attempt key, and audited runtime.ml for remaining die_of_exn_runtime catch-alls. Verified with nix develop -c dune runtest --force."
---

# P2: retry_eff catch-all must use cause_of_exn_runtime

## description

Bug: packages/eta/runtime.ml line 1130 (retry_eff catch-all) is '| exn -> raise_cause fail_key (die_of_exn_runtime runtime exn)'. Tap_error (line 467) and most other interpreter sites use cause_of_exn_runtime for the same shape. cause_of_exn_runtime translates Eio.Exn.Multiple, internal Raised_cause under another key, Exit, Fun.Finally_raised etc. into structured causes; die_of_exn_runtime collapses everything into Die. The asymmetry downgrades retry-time control-flow exceptions into defects.

Location: packages/eta/runtime.ml retry_eff (line 1130)

## design

RED test (write first):
1. Construct an effect that, under retry, raises Eio.Exn.Multiple [exn1; exn2] (or another exception class that cause_of_exn_runtime translates differently from die_of_exn).
2. Run via Runtime.run rt (Effect.retry sched (fun _ -> false) eff) — predicate false to immediately surface the cause.
3. Assert the resulting cause is the structured shape (e.g., Cause.Concurrent [...]), not Cause.Die.
4. Currently the result is Cause.Die _.

Regression check:
- Existing typed-failure retry tests still pass.

Fix shape:
- Change line 1130 to '| exn -> raise_cause fail_key (cause_of_exn_runtime runtime attempt_key exn)'.
- Audit other die_of_exn_runtime catch-all sites for the same asymmetry; promote where appropriate.

## acceptance criteria

RED test fails on current code and passes after the fix. Existing retry tests for typed failures still pass. Audit notes any other catch-all sites that should be promoted.
