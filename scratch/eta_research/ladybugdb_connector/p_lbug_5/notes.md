# P-Lbug-5 - Fairness Under Effect.blocking

Status: Partial
Verdict: Partial - a bounded 5-second fairness run with 16 heartbeat fibers stayed under the 10ms p99 jitter budget while a LadybugDB query ran through Effect.blocking and was cancelled by timeout. The requested 30-second run did not produce a summary before the outer timeout, so the full 30-second obligation remains unproven.

## Command

Captured log:

scratch/eta_research/ladybugdb_connector/p_lbug_5/p_lbug_5.log

Command used:

nix develop -c env LD_LIBRARY_PATH=/tmp/ladybug/build/src timeout 20s dune exec scratch/eta_research/ladybugdb_connector/p_lbug_5/p_lbug_5_probe.exe

The log was captured with stdout/stderr redirected to p_lbug_5.log.

## What Was Tested

- Created 20,000 N nodes.
- Started a long LadybugDB query through Effect.blocking.
- Used on_cancel=lbug_connection_interrupt and Effect.timeout.
- Ran 16 Eio heartbeat fibers with 1ms target interval.
- Collected jitter samples for 5 seconds.
- Checked connection reuse after timeout.

## Evidence

Relevant lines from p_lbug_5.log:

    heartbeat_fibers=16
    heartbeat_interval_ms=1
    sample_seconds=5
    samples=80016
    jitter_p50_ms=0.009
    jitter_p99_ms=0.054
    jitter_max_ms=4.366
    query_result=Error:Timeout
    query_finished=true
    connection_reusable=true
    verdict=Partial_5s_window

## Surprise Findings

- The same fixture set to a 30-second sample window did not emit a summary before the outer timeout, despite the 5-second version completing cleanly. This may be a fixture issue around the long-running query/timeout interaction, but the 30-second fairness claim is not proven.
- The 5-second p99 was much lower than the threshold, which suggests Effect.blocking itself is not starving co-fibers in the measured window.

## What Was Not Measured

- The objective's full 30-second p99 jitter window remains unproven.
- No CPU utilization or domain scheduling profile was captured.
- No repeated fairness runs were collected.
- No comparison against a direct non-Effect.blocking call was collected in this probe.

## Stop/Continue Decision

P-Lbug-5 is Partial but does not trigger a stop condition. Continue to P-Lbug-6.
