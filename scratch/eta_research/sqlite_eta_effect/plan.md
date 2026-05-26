# Research Plan

## Decision Question

Where, on what thread, and through which Eta primitive should sqlite3_step run
so that:

- slow queries do not starve other Eio fibers in the calling domain;
- cancellation propagates through sqlite3_interrupt and leaves the connection
  reusable;
- per-call overhead is acceptable for the smallest realistic query;
- transactions spanning multiple statements are expressible without exposing
  thread or worker identity to user code;
- SQLITE_BUSY composes with Effect.retry and Schedule.

## Hypotheses

- A: same-domain synchronous sqlite3_step.
- B: per-call systhread offload via Effect.blocking.
- C: connection-pinned worker systhread, with a request channel per connection.
- D: pool of connection plus worker pairs, likely reader pool plus writer
  singleton under WAL.
- E: Eta.island CPU offload.

## Proof Ladder

- Rung 0, workload profile: set latency bars, representative queries, threading
  mode, and writer model.
- Rung 1, F-Block: run representative direct sqlite3_step calls while co-fibers
  wake every 1 ms. This can reject A.
- Rung 2, F-Floor: compare smallest-query floor latency for B versus C with at
  least 20 samples and dispersion.
- Rung 3, F-Cancel: run a long statement, cancel via Effect.timeout, interrupt
  SQLite, and prove the worker/pool slot and connection survive.
- Rung 4, F-Affinity: stress B with two fibers touching one sqlite3 handle under
  SQLite serialized mode.
- Rung 5, F-Tx: prove transactions pin one connection across many statements and
  reject concurrent interleaving on the same connection.
- Rung 6, F-Busy: prove SQLITE_BUSY maps to typed retry and does not amplify tail
  latency under writer contention.
- Rung 7, F-Pool-Asymmetry: only if D advances, prove WAL reader pool plus
  writer singleton fits Eta.Pool/Semaphore without a new primitive.

## Current Artifacts

- sqlite_blocking_probe.ml: early F-Block orientation for lock contention.
- sqlite_floor_probe.ml: F-Floor comparison of per-call Effect.blocking and a
  private connection-pinned worker prototype.
- sqlite_cancel_probe.ml: F-Cancel probe for naive timeout versus explicit
  sqlite3_interrupt.
- sqlite_affinity_probe.ml: F-Affinity stress for B under serialized SQLite.
- sqlite_tx_probe.ml: F-Tx probe for transaction pinning through Eta.Pool.
- sqlite_busy_probe.ml: F-Busy probe for Effect.retry plus Schedule over
  SQLITE_BUSY.
- results.md: command output and current evidence status.
- workload_profile.md: open product bars that must be answered before final
  design selection.

## Primitive Constraints Found

- Eta.Channel is same-domain and is therefore not a valid cross-systhread worker
  queue for C.
