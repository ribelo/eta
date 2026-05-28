# Turso Connector Research Lab

Decides the connector and execution shape for `packages/sql/` to support
Turso alongside SQLite. Anchored on **embedded analytical store for
application data** (100k–10M rows, mixed read/write, window aggs / joins /
group-bys, ≤16 concurrent fibers per Database).

This README is the lab index. The full plan, hypotheses, falsifiers, and
acceptance criteria live in `../../../OBJECTIVE_TURSO.md` at the worktree root.

---

## Decision Question (one-line)

What connector + iteration + Pool + Value + builder shape should `packages/sql/`
adopt for Turso so that BEGIN CONCURRENT improves write throughput, async I/O
reduces syscall overhead, and the existing typed builder is reused?

The architectural sub-decision: **engine-generalize** the existing `Sql`
library or **split** into `Sql_sqlite` + `Sql_turso` sharing the typed
builder.

---

## Hypothesis Ledger (mirror — see OBJECTIVE_TURSO.md for full text)

| ID   | One-line                                                                                        | Probe |
| ---- | ----------------------------------------------------------------------------------------------- | ----- |
| H-1  | `Effect.blocking` with Turso keeps co-fiber wake-jitter ≤10ms p99.                             | P1    |
| H-2  | BEGIN CONCURRENT allows concurrent writes without SQLITE_BUSY.                                  | P2    |
| H-3  | Async I/O (io_uring) reduces syscall overhead ≥10%.                                             | P3    |
| H-4  | Turso requires same Value type as SQLite (7-case).                                              | P4    |
| H-5  | Current builder covers ≥90% of Turso queries.                                                   | P5    |
| H-6  | Encryption at rest integrates cleanly with connector.                                           | P6    |
| H-7  | Database/Connection fits Eta_pool with parameter changes only.                                  | P7    |
| H-8  | Sql library can be generalized over Engine signature covering SQLite and Turso.                 | P8    |
| H-9  | CDC can be exposed as reactive stream via Eta Channel.                                          | P9    |
| H-10 | Vector search works natively with typed builder.                                                | P9    |
| H-11 | Turso connector requires no new Eta primitives.                                                 | P11   |

---

## Probe Order (hardest first, stop at falsifier)

- **P0** — Turso C API survey + dependency probe.
- **P1** (HARD) — Long-query fairness probe. Co-fibers tick 1ms; sample wake-jitter.
- **P2** (HARD) — BEGIN CONCURRENT concurrent write correctness.
- **P3** — Async I/O (io_uring) vs synchronous I/O comparison.
- **P4** — 10-query type coverage inventory.
- **P5** — Same 10 queries against the current builder.
- **P6** — Encryption at rest probe.
- **P7** — Database/Connection lifetime against `Eta_pool.create`.
- **P8** — Engine generalize vs split — paper sketch + ADR.
- **P9** — CDC / Vector search / primitive-gap confirmations.

Stop conditions are in OBJECTIVE_TURSO.md §"Stop Conditions".

---

## Methodology

- Popperian: every hypothesis has an explicit disproof signature.
- Hardest-first: P1 / P2 / P3 are load-bearing; if any fails, the connector
  shape changes and the lab pauses to re-plan.
- Steelman before testing: the strongest version of every alternative is
  expressed concretely before its falsifier is built.
- "Hard to test" is never a verdict.

---

## References

- Master plan: `../../../OBJECTIVE_TURSO.md`.
- Prior SQLite work: `scratch/eta_research/sqlite_fast/`,
  `scratch/eta_research/sqlite_eta_effect/`.
- Prior DuckDB work: `scratch/eta_research/duckdb_connector/`.
- Current builder + connector: `packages/sql/sql.mli`,
  `packages/sql/sqlite.mli`. Treat as parent shape.
- `Effect.blocking ?on_cancel` cancellation hook: `packages/eta/effect.mli`.
- Pool: `packages/eta/pool.mli`.
