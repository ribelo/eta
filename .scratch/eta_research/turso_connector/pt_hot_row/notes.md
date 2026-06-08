# P-Turso-2 - Hot Row Contention

Status: **Partial**

Evidence:
- build log: build.log
- contention log: contention.log

The corrected fixture uses 16 native workers, 100 transactions per worker,
file-backed MVCC, BEGIN CONCURRENT, and at most 10 retries per transaction.

Verdicts by scale:
- 1 hot row: **Falsified**. Counter reached 1039/1600; 561 transactions
  exhausted the retry cap.
- 4 hot rows: **Falsified**. Counter reached 1103/1600; 497 transactions
  exhausted the retry cap.
- 16 hot rows / no overlap: **Confirmed**. Counter reached 1600/1600 with no
  retries or generic errors.

Surprise: conflicts surfaced as generic rc=1, xrc=0, msg=not an error, not as
SQLITE_BUSY or SQLITE_LOCKED.

Retry policy evidence: a 10-attempt policy is not sufficient under 1-row or
4-row contention. BEGIN CONCURRENT only carried the no-overlap control in this
run.

