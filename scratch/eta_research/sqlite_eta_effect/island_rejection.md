# Eta.island Rejection Memo

Status: rejected for SQLite connector execution.

Eta.island is for portable CPU-bound callbacks and finite CPU batches. SQLite
handles are opaque C pointers owned by a process-local SQLite connection. They
are not immutable-data payloads, not portable values, and not a CPU workload.

Using island for sqlite3_step would also solve the wrong problem. The database
call may block on file locks, fsync, or busy timeout. That is legacy blocking
I/O, which belongs either in Effect.blocking or in a dedicated connection
worker design, depending on the B/C evidence.

Verdict: E is out of scope for implementation unless Eta's island contract
changes to support non-portable resource-owned I/O handles, which would be a
separate Eta runtime design.
