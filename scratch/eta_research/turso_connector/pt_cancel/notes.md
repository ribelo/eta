# P-Turso-3 - Cancellation

Status: **Falsified**

Evidence:
- build log: build.log
- cancellation log: cancel.log

The cancellation fixture attempted long-running SELECT work with
sqlite3_interrupt. Turso aborted the process from Rust before a structured
SQLITE_INTERRUPT result could be observed. This reproduced after replacing the
initial recursive CTE with a large cross-join query.

Observed failure:
- process exit: 134
- panic: called Result.unwrap on ConversionError(Expected integer value)

The BEGIN CONCURRENT cancellation subcase did not run because the first
cancellation case aborted the process. Production implementation must treat
timeout cancellation as a shipping gate, not as proven.
