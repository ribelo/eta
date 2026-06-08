# P-Turso-5 - MVCC/WAL Interaction

Status: **Partial**

Evidence:
- build log: build.log
- journal log: journal.log
- close sanity: close_crash.log
- crash-recovery blocker: blocker.md

Observed sequence:

1. Initial file-backed database reported journal_mode=wal.
2. PRAGMA journal_mode = wal returned wal.
3. PRAGMA journal_mode = mvcc returned mvcc.
4. Inspecting PRAGMA journal_mode returned mvcc.
5. Closing after WAL to MVCC returned rc=0 in the corrected fixture.
6. Reverse order was deterministic: MVCC then WAL reported WAL.
7. A second connection observed MVCC after the first connection set MVCC.

The behavior is deterministic last-writer-wins, not undefined. The driver can
paper over this by making MVCC and WAL mutually exclusive in config and by
setting/verifying the selected mode explicitly. Crash recovery remains Untested.
