# Observability Results

Status: labels, stats, and timing summaries are required for v1.

## What Was Tested

The probes cover pool counters, per-job timing collection, and operation labels.

## Evidence

| Probe | Result |
| --- | --- |
| pool stats | active, idle, queued, completed, rejected, cancelled, detached, and peak counters emitted |
| job timings | 4 timing samples, 20 ms total run time |
| trace labels | labels recorded: `pg.query`, `legacy.fs.read`, `aws-sdk.put` |

## Consequence

The blocking API needs observable pool state from the first implementation.
Without counters and labels, users cannot tell whether a slowdown is caused by
resource saturation, queueing, rejected work, or a bad operation class.

Minimum v1 telemetry:

- pool name,
- operation label,
- active workers,
- queued jobs,
- completed jobs,
- rejected jobs,
- cancelled-before-start jobs,
- detached-after-cancel jobs,
- peak active workers,
- peak queued jobs,
- per-job queued/run timing.
