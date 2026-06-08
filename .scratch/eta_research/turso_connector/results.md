# Turso Connector Research v2 - Results

Status: **COMPLETE - accepted for implementation planning with gates**

The prior Turso pass's paper-analysis verdicts are demoted to **Untested**.
Only logs listed in this file count as evidence for v2.

## Probe Status

| Probe | Status | Evidence |
| --- | --- | --- |
| P-Turso-1 ENGINE fit | Confirmed | pt_engine_fit/build.log, pt_engine_fit/smoke.log |
| P-Turso-2 hot-row contention | Partial | pt_hot_row/contention.log |
| P-Turso-3 cancellation | Falsified | pt_cancel/cancel.log |
| P-Turso-4 pool fit | Partial | pt_pool/build.log, pt_pool/pool.log |
| P-Turso-5 MVCC/WAL | Partial | pt_journal/build.log, pt_journal/journal.log, pt_journal/close_crash.log, pt_journal/blocker.md |
| P-Turso-6 error codes | Partial | pt_error_codes/errors.log |

## Prior Pass Demotion

The earlier P3 async I/O, P4 type coverage, P5 builder coverage, P6
encryption, P7 pool, P8 generalization, and P9 confirmation paper claims are
**Untested** for this objective. They are not used as shipping evidence.

## Current Findings

- Turso can satisfy the accepted ENGINE.S shape in a bounded link/smoke
  fixture with sqlite3_column_int64 replacing the missing sqlite3_column_int.
- BEGIN CONCURRENT did not carry overlapping hot-row writes under a 10-retry
  cap. It passed only the no-overlap 16-row control.
- Conflict surfaces were generic: rc=1, xrc=0, msg=not an error.
- Cancellation did not produce a clean interrupt result; the process aborted.
- File-backed Pool safe ordering works, but unsafe database-close-before-pool
  ordering is not supported and was isolated in a child process.
- MVCC/WAL interaction is deterministic last-writer-wins. WAL then MVCC reports
  mvcc; MVCC then WAL reports wal; a second connection observes mvcc after the
  first connection sets it. The corrected close sanity probe returned rc=0.
- Crash recovery remains Untested and documented in pt_journal/blocker.md.

## Implementation Planning Verdict

Implementation can begin against adr.md, but the ADR carries hard gates:
timeout cancellation is not proven and must not be advertised as safe until a
new fixture stops aborting, and Turso config must make MVCC/WAL selection
explicit rather than silently inheriting SQLite WAL defaults.
