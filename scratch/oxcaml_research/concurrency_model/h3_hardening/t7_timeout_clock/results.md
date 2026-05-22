# T7 Timeout And Clock Results

## Verdict

The coordinator computes a portable deadline payload as int64 monotonic nanoseconds. Workers compare the payload against their local clock at the same polling points as T2.

Schedule.jittered must not use implicit global RNG inside portable workers. H3 moves jitter to coordinator-generated delays or an explicit portable PRNG capability.

## Evidence

Command: nix develop -c bash scratch/oxcaml_research/concurrency_model/h3_hardening/t7_timeout_clock/run.sh

| Fixture | Result | Evidence |
| --- | --- | --- |
| timeout_clock_positive.ml | PASS | Timeout vs sibling success, sibling failure, and mid-loop CPU all passed; max_deadline_to_exit_us=48417. |
| eio_clock_capture_negative.ml | PASS expected-fail | Eio.Time.now capture rejected across worker boundary. |
| random_state_capture_negative.ml | PASS expected-fail | Random.State.t capture rejected. |

Summary: pass=3 fail=0.

## Pinned Invariant

Timeout is a coordinator deadline plus worker-local polling. Raw Eio clocks and RNG state do not cross domains.

