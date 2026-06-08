# C6 H4 Reopen Telemetry

## Metric Definitions

Emit these through the existing Capabilities.meter surface:

| Metric | Kind | Unit | Attributes | Definition |
| --- | --- | --- | --- | --- |
| effet.h3.domain.idle_spin_ratio | Gauge Float | 1 | domain, scheduler_id | Idle polling time divided by scheduler window wall time for one domain. |
| effet.h3.domain.queue_depth | Gauge Int | task | domain, scheduler_id | Pending runnable tasks assigned to the domain at sample time. |
| effet.h3.scheduler.completed_tasks | Counter Monotonic Int | task | scheduler_id | Tasks completed in the scheduler window. |

## H4 Reopen Criterion

Reopen H4 steal-on-empty design when this threshold is met:

p95(effet.h3.domain.idle_spin_ratio) > 0.35
AND max(effet.h3.domain.queue_depth) > 0
for 3 consecutive 60s scheduler windows
in at least 5% of production runs for the same workload class.

The queue-depth guard prevents reopening H4 for genuinely idle systems. The
three-window guard filters transient skew. The 5% run threshold keeps rare
outliers from forcing a scheduler redesign.

## Implementation Hook

The H3 runtime can compute these metrics inside the coordinator because explicit
least-loaded assignment already knows per-domain task counts, completions, and
idle windows. No new observability surface is required.
