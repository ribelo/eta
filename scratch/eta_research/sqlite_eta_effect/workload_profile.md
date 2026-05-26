# Workload Profile

Status: preliminary defaults are in use until product-specific answers are
provided. Results using these defaults are decision evidence for the current
experiment, but they remain easier to overturn than measurements tied to a real
application workload.

## Required Inputs

1. Workload shape:
   - many-small: web/API/cache style, small statements, sub-ms co-fiber P99
     matters under load;
   - few-big: analytics/admin style, queueing is acceptable and throughput
     matters more than individual floor latency;
   - mixed: state the expected split.

2. SQLite threading mode:
   - serialized: one sqlite3 handle may be used by multiple threads if calls are
     externally coherent; this keeps B on the board;
   - multi-thread: one handle must not be used by multiple threads at once; this
     effectively forces connection affinity and makes C/D stronger.

3. Writer model:
   - generic operation API: user calls query/execute and the connector handles
     contention;
   - explicit read/write API: user or DSL marks reader vs writer, allowing WAL
     reader pool plus writer singleton experiments.

## Preliminary Bars

Assumptions currently used by probes:

- workload shape: many-small or mixed, where co-fiber latency matters;
- SQLite threading mode: serialized, because this keeps per-call offload on the
  board until F-Affinity contradicts it;
- writer model: generic query/execute API, with read/write specialization only
  if D later earns it;
- co-fiber wake P99 during one query: <= 1 ms preliminary bar;
- smallest realistic query: prepared primary-key lookup returning one row;
- representative mid query: indexed range scan or aggregate over about 10k rows;
- representative large query: WITH RECURSIVE or writer contention held to the
  configured busy timeout.
- representative scan query: 200k-row ordered integer scan. F-Scan rejects
  per-row blocking handoff and selects bounded blocking batches for Eta_pool
  scan/fold APIs.

Would change if:

- target workload is analytics/few-big, making queueing and throughput more
  important than per-call floor latency;
- SQLite is compiled/configured in multi-thread mode, forcing connection
  affinity;
- the public API requires explicit reader/writer operations, making D cheaper to
  expose.
- a real consumer proves that 10-30 ms same-domain scan stalls are acceptable
  and lower allocation matters more than co-fiber fairness; that would reopen
  A' as an explicit expert-mode scan path, not as the default Eta path.
