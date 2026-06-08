# T1 Inbox Protocol Results

## Verdict

H3 uses spec (a): a single coordinator producer fills each worker inbox, closes it, and only then may the worker drain it. Concurrent push/drain and multi-producer push are outside the H3 baseline.

The inbox primitive is a coordinator-owned Portable.Atomic list plus count and close flag. It is not a general multi-producer bounded queue.

## Evidence

Command: nix develop -c bash scratch/oxcaml_research/concurrency_model/h3_hardening/t1_inbox/run.sh

| Fixture | Result | Evidence |
| --- | --- | --- |
| phase_separated_positive.ml | PASS | accepted=32 drained=32; drain restored push order. |
| capacity_positive.ml | PASS | accepted=3 rejected=3; capacity bound observed. |
| close_positive.ml | PASS | Closed inbox rejects late push. |
| two_producer_race_negative.ml | PASS | Detected stale capacity race: capacity=1 count=2 items=2. |
| mixed_push_drain_negative.ml | PASS | Detected count/items mismatch: drained=2 stale_count=1. |
| push_after_close_negative.ml | PASS | Detected missing close contract: late_items=1. |

Summary: pass=6 fail=0.

## Pinned Invariant

Phase-separated inbox ownership is mandatory. If a future runtime needs concurrent producers or push/drain overlap, H3 must replace this inbox with a real linearizable bounded queue before shipping.

