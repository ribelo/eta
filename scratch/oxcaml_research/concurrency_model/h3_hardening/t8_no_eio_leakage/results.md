# T8 Eio Non-Leakage Results

## Verdict

The H3 worker boundary mechanically rejects raw same-domain Eio handles, same-domain collectors, raw Cause.t, and Runtime.t. Portable replacements cross successfully.

## Evidence

Command: nix develop -c bash scratch/oxcaml_research/concurrency_model/h3_hardening/t8_no_eio_leakage/run.sh

| Forbidden capture | Fixture | Result |
| --- | --- | --- |
| Eio.Switch.t | switch_capture_negative.ml | PASS expected-fail |
| Eio.Promise.t | promise_capture_negative.ml | PASS expected-fail |
| Eio.Stream.t / Eio.Stream.add | stream_capture_negative.ml | PASS expected-fail |
| Eio.Cancel.t | cancel_capture_negative.ml | PASS expected-fail |
| Eio.Time.clock | clock_capture_negative.ml | PASS expected-fail |
| Eio.Std.r | stdenv_capture_negative.ml | PASS expected-fail |
| Tracer.in_memory | tracer_capture_negative.ml | PASS expected-fail |
| Logger.in_memory | logger_capture_negative.ml | PASS expected-fail |
| Meter.in_memory | meter_capture_negative.ml | PASS expected-fail |
| Raw Cause.t | raw_cause_capture_negative.ml | PASS expected-fail |
| Runtime.t | runtime_capture_negative.ml | PASS expected-fail |

Positive control: portable_replacements_positive.ml passed with Cause.Portable.t, trace context, Portable.Atomic, Schedule.t, Duration.t, and Sampler.t values.

Summary: pass=12 fail=0.

## Pinned Invariant

Workers capture portable data and coordinator-supplied portable atomics only. Same-domain runtime resources stay on the owning domain.

