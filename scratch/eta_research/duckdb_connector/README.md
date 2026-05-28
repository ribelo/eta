# DuckDB Connector Research Lab

Decides the connector and execution shape for `packages/sql/` to support
DuckDB alongside SQLite. Anchored on **embedded analytical store for
application data** (100k–10M rows, mixed read/write, window aggs / joins /
group-bys, ≤16 concurrent fibers per Database).

This README is the lab index. The full plan, hypotheses, falsifiers, and
acceptance criteria live in `../../../OBJECTIVE.md` at the worktree root.

---

## Decision Question (one-line)

What connector + iteration + Pool + Value + builder shape should `packages/sql/`
adopt for DuckDB so that long OLAP queries do not stall co-fibers, cancellation
through `duckdb_interrupt` is clean, and the existing typed builder is reused
where engine-neutral?

The architectural sub-decision: **engine-generalize** the existing `Sql`
library or **split** into `Sql_sqlite` + `Sql_duckdb` sharing the typed
builder.

---

## Hypothesis Ledger (mirror — see OBJECTIVE.md for full text)

| ID   | One-line                                                                                        | Probe |
| ---- | ----------------------------------------------------------------------------------------------- | ----- |
| H-1  | `Effect.blocking ?on_cancel:duckdb_interrupt` keeps co-fiber wake-jitter ≤10ms p99.             | P1    |
| H-2  | `duckdb_interrupt` mid-query is clean and connection / statement reusable.                      | P2    |
| H-3  | Chunk iteration is the right primary scan shape; per-row API is unnecessary.                    | P3    |
| H-4  | DuckDB needs a richer Value type than SQLite's closed 7-case variant.                           | P4    |
| H-5  | Current `Sql.Select` builder covers ≥80% of analytical queries; tail extends cleanly.           | P5    |
| H-6  | Appender / COPY warrant first-class API; per-row INSERT is wrong-shaped for bulk.               | P6    |
| H-7  | Database-then-Connection fits Eta_pool with parameter changes only.                             | P7    |
| H-8  | The `Sql` library can be generalized over an Engine signature without complicating SQLite.     | P8    |
| H-9  | Chunk API is sufficient for v1; Arrow zero-copy is deferred.                                    | P9    |
| H-10 | Default extensions (parquet/json/httpfs) autoload; no special `LOAD` API.                       | P9    |
| H-11 | DuckDB connector requires no new Eta primitives.                                                | P11   |

---

## Probe Order (hardest first, stop at falsifier)

- **P0** — DuckDB C API survey + `pkg-config duckdb` + 10-line link probe.
- **P1** (HARD) — Long-OLAP fairness probe. Co-fibers tick 1ms; sample wake-jitter.
- **P2** (HARD) — `duckdb_interrupt` mid-query correctness; connection / statement reuse.
- **P3** (HARD) — Chunk vs full-materialize vs per-row iteration; alloc + wall-time.
- **P4** — 10-query type coverage inventory (DECIMAL/TIMESTAMP/UUID/LIST/STRUCT/ENUM).
- **P5** — Same 10 queries against the current builder; mark expressible / extension / raw-SQL.
- **P6** — 1M-row insert: per-row vs batched VALUES vs Appender (vs COPY for secondary).
- **P7** — Database/Connection lifetime against `Eta_pool.create`; fanout fixture.
- **P8** — Engine generalize vs split — paper sketch + ADR.
- **P9** — Arrow / extensions / primitive-gap confirmations.

Stop conditions are in OBJECTIVE.md §"Stop Conditions". P1 / P2 failures pause
the lab and force a re-plan.

---

## Working Directory Conventions

Each probe gets its own subdirectory:

```
scratch/eta_research/duckdb_connector/
  README.md                     ← this file
  plan.md                       ← detailed probe-level plan (write before P0)
  results.md                    ← running record of evidence + verdicts
  adr.md                        ← H-8 verdict (engine-generalize vs split)
  workload_profile.md           ← 10-query inventory (P4 input, P5 input)

  p0_duckdb/                    ← C API survey + link probe
  p1_fairness/                  ← H-1 long-query co-fiber jitter
  p2_cancel/                    ← H-2 interrupt mid-query
  p3_iter/                      ← H-3 chunk vs materialize vs row
  p4_type_coverage/             ← H-4 type inventory + widening cost
  p5_builder_coverage/          ← H-5 builder gap analysis
  p6_bulk_load/                 ← H-6 Appender vs INSERT batched
  p7_pool/                      ← H-7 Pool fit
  p8_generalize/                ← H-8 engine generalize design probe
```

Each subdirectory has its own `dune` stanza so probes are runnable as
`dune exec scratch/eta_research/duckdb_connector/<probe>/<exe>.exe`.

---

## Methodology

- Popperian: every hypothesis has an explicit disproof signature. A probe that
  cannot falsify is not worth running.
- Hardest-first: P1 / P2 / P3 are load-bearing; if any fails, the connector
  shape changes and the lab pauses to re-plan.
- Steelman before testing: the strongest version of every alternative
  (per-connection worker thread, materialized result, split libraries) is
  expressed concretely before its falsifier is built.
- "Hard to test" is never a verdict. Cost to investigate is not evidence.
- Status-language: `Confirmed`, `Rejected`, `Deferred`, `Out of scope`.
  Never "rejected" when "untested" is honest.

---

## Out of Scope (do not expand)

- Arrow C-data interop. Its own lab if a consumer demands it.
- Replacing the SQLite connector.
- Networked / cloud DuckDB (MotherDuck).
- Multi-process Database sharing.
- ORM / active-record / framework surface.
- SQL-literal PPX.

---

## References

- Master plan: `../../../OBJECTIVE.md`.
- Prior SQLite work: `scratch/eta_research/sqlite_fast/`,
  `scratch/eta_research/sqlite_eta_effect/`. Same lab shape, different engine.
- Current builder + connector: `packages/sql/sql.mli`,
  `packages/sql/sqlite.mli`. Treat as parent shape.
- `Effect.blocking ?on_cancel` cancellation hook: `packages/eta/effect.mli`.
- Pool: `packages/eta/pool.mli`.
- Methodology: `evidence-based-coding` and `oxcaml` skills.
