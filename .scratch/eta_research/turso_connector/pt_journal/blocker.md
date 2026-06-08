# P-Turso-5 Crash Recovery Blocker

The PRAGMA-order and cross-connection portions of P-Turso-5 are runnable in
journal.log.

The crash-recovery subprobe is marked **Untested**. The first implementation
used fork() to leave a process mid-BEGIN CONCURRENT transaction. That shape is
not a fair recovery harness for a Rust-backed C library already initialized in
the parent process.

Smallest fair workaround: rewrite crash recovery as a separate executable that
is launched by a parent harness and killed from the outside, so the Turso/Rust
library is not exercised across fork() inside an already-initialized process.
