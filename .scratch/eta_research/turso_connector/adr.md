# ADR - Turso Connector v2

Status: **Accepted for implementation planning with gates**

## Decision

Begin the Sql.Turso implementation only with the gates below carried into the
implementation task. The lab supports the ENGINE fit and the public Shape B
surface, but it does not support advertising cancellation safety or transparent
WAL compatibility.

## Evidence Summary

- ENGINE fit: confirmed by pt_engine_fit/build.log and pt_engine_fit/smoke.log.
- BEGIN CONCURRENT retry policy: partial. No-overlap writes need no retry, but
  1-row and 4-row hot contention exhausted the 10-retry cap.
- Cancellation: falsified by pt_cancel/cancel.log. sqlite3_interrupt caused a
  Turso/Rust abort in the tested long-query cases.
- Pool fit: partial. Safe pool shutdown before database close works; unsafe
  database close while pool is live is not supported.
- MVCC/WAL: partial. journal_mode is deterministic last-writer-wins:
  WAL->MVCC yields mvcc; MVCC->WAL yields wal; a second connection observes
  mvcc after the first sets it. Crash recovery is Untested.
- Error mapping: partial; conflicts surfaced as generic rc=1, xrc=0,
  msg=not an error.

## Public Shape

- Sql.Turso.config
- Sql.Turso.Engine : ENGINE
- Sql.Turso.transaction ~mode:[Read | Write | Concurrent] f
- Sql.Turso.retry_on_conflict ~max_attempts ~backoff f

## Config Rules

- config must make journal choice explicit: Mvcc or Wal, not both.
- transaction mode Concurrent requires Mvcc.
- opening with Mvcc must issue PRAGMA journal_mode = 'mvcc' and verify the
  observed mode before returning the database handle.
- opening with Wal must issue PRAGMA journal_mode = 'wal' and verify wal.

## BEGIN CONCURRENT Retry Policy

The retry helper may be implemented, but it must be documented as a conflict
recovery helper, not a guarantee that hot-row contention converges.

- no-overlap control: 16 workers x 100 updates committed 1600/1600 with zero
  retries, so no retry is needed for disjoint writes.
- 1 hot row and 4 hot rows: a 10-attempt cap did not converge, so the helper
  must expose max_attempts and backoff rather than hard-coding 10 as safe.
- conflict detection in this Turso build surfaced as generic rc=1/xrc=0, so
  the first implementation can only retry generic transaction failures that
  occur inside Concurrent mode, and should leave a TODO to replace that with a
  structured Turso conflict code if one becomes available.

## Reused Surfaces

The ENGINE, Pool lifecycle invariant, Decoder surface, and schema PPX shape
remain accepted prior art. This lab did not reopen them.

## v0.1 Scope

Keep v0.1 limited to SQLite-compatible execution plus explicit
BEGIN CONCURRENT. Encryption, vector search, async I/O, and CDC stay deferred.

## Known Gaps Before Implementation

- Crash recovery in MVCC mode is Untested.
- Re-run cancellation with a fixture or upstream version that returns
  SQLITE_INTERRUPT instead of aborting.
- Decide whether generic rc=1 conflict errors are acceptable for a retry
  helper, or whether Turso needs a better diagnostic surface first.

## Shipping Gates

- Do not document timeout cancellation as supported until P-Turso-3 has a
  non-aborting interrupt log.
- Do not silently preserve an application WAL default when Concurrent mode is
  requested; Concurrent mode must choose and verify MVCC.
