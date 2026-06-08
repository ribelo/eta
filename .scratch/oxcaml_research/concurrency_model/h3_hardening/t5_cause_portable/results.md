# T5 Cause.Portable Results

## Verdict

H3 workers return real Effet.Cause.Portable.t values. The typed-error payload must be value mod portable; raw same-domain Cause.t cannot cross the worker boundary.

Worker-side failures construct Cause.Portable directly. The coordinator may render or aggregate those portable causes, but it must not rely on raw exn identity after crossing the boundary.

## Evidence

Command: nix develop -c bash scratch/oxcaml_research/concurrency_model/h3_hardening/t5_cause_portable/run.sh

| Fixture | Result | Evidence |
| --- | --- | --- |
| die_positive.ml | PASS | Die materialized with string diagnostics. |
| fail_positive.ml | PASS | Closed typed payload crossed as Fail. |
| interrupt_positive.ml | PASS | Interrupt crossed. |
| concurrent_positive.ml | PASS | Concurrent preserved two siblings. |
| suppressed_positive.ml | PASS | Suppressed preserved primary and finalizer. |
| open_polyvariant_error_negative.ml | PASS expected-fail | Open polyvariant rejected as not value mod portable. |
| closure_payload_negative.ml | PASS expected-fail | Function payload rejected as not portable. |
| raw_cause_negative.ml | PASS expected-fail | Raw same-domain cause rejected as nonportable. |

Summary: pass=8 fail=0.

## Pinned Invariant

Failure payloads crossing domains are Cause.Portable Die, Fail, Interrupt, Concurrent, and Suppressed only, with portable typed-error payloads.

