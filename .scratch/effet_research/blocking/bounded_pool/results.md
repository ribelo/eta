# Bounded Pool Results

Status: B2 accepted as the default blocking I/O shape.

## What Was Tested

The scratch pool is a bounded Effet-facing admission layer over
`Eio_unix.run_in_systhread`. It models:

- `max_threads`,
- `max_queued`,
- `Wait` and `Reject`,
- stats,
- job timings,
- shutdown state.

It is not a final custom worker-thread implementation.

## Evidence

| Probe | Result |
| --- | --- |
| smoke | one job completed, peak active 1, peak queued 1 |
| Wait backpressure | 3 jobs completed with `max_threads=1` and queueing |
| Reject backpressure | 4 submissions rejected deterministically |
| stress thread count | 100 jobs completed with `peak_active_threads=4`, `peak_queued_jobs=64`, `threads_after=6`, heartbeat p99 12 us |
| shutdown started job | started work finished after shutdown |
| shutdown pending jobs | queued/started work drained under the prototype contract |

The direct matrix shows the tradeoff:

| Mode | Jobs | Elapsed | Threads after | Heartbeat p99 |
| --- | --- | --- | --- | --- |
| raw `run_in_systhread` | 100 | 4899 us | 102 | 20 us |
| bounded pool | 100 | 76967 us | 6 | 11 us |

## Consequence

B2 is slower for very short bursty sleeps, but it bounds resource growth and
makes backpressure observable. That is the right default for a general Effet
library boundary.

The production implementation still needs to decide whether to keep the Eio
systhread substrate or own worker threads directly. If exact idle-timeout
behavior is part of the contract, the implementation epic must prove it.
