# LadybugDB Connector Research Lab

Decides the connector shape for integrating LadybugDB (embedded graph database, formerly Kuzu) with Eta. This is fundamentally different from relational databases — LadybugDB uses **Cypher** (not SQL) and a **property graph model** (not tables).

This README is the lab index. The full plan lives in `../../../OBJECTIVE_LADYBUGDB.md`.

---

## Decision Question (one-line)

Should Eta integrate LadybugDB via a new `packages/graph/` module or by extending `packages/sql/` with a Cypher escape hatch?

---

## Hypothesis Ledger

| ID   | One-line                                                                                        | Probe |
| ---- | ----------------------------------------------------------------------------------------------- | ----- |
| H-1  | `Effect.blocking` with LadybugDB keeps co-fiber wake-jitter ≤10ms p99.                         | P1    |
| H-2  | Multiple connections to same Database can execute concurrent queries safely.                    | P2    |
| H-3  | Arrow C data interface provides zero-copy access to query results.                              | P3    |
| H-4  | Property graph model maps cleanly to OCaml algebraic types.                                     | P4    |
| H-5  | Cypher queries can be parameterized for safe execution.                                         | P5    |
| H-6  | Database/Connection lifetime fits Eta_pool.                                                     | P6    |
| H-7  | New `packages/graph/` is cleaner than extending `packages/sql/`.                                | P7    |
| H-8  | No new Eta primitives needed.                                                                   | P8    |

---

## Probe Order

- **P0** — C API survey + dependency probe
- **P1** (HARD) — Fairness probe
- **P2** (HARD) — Concurrent query probe
- **P3** — Arrow integration probe
- **P4** — Type mapping probe
- **P5** — Parameterization probe
- **P6** — Pool fit probe
- **P7** — Architecture decision (ADR)
- **P8** — Primitive gap audit

---

## Key Differences from SQL Databases

| Feature | SQLite/DuckDB/Turso | LadybugDB |
|---------|---------------------|-----------|
| Query language | SQL | Cypher |
| Data model | Tables (rows/columns) | Property Graph (nodes/relationships) |
| Iteration | Row-at-a-time or chunks | Arrow C data interface |
| Joins | Explicit JOIN clauses | Pattern matching |
| Types | Scalar (int, string, blob) | Graph (Node, Relationship, Path) |

---

## References

- Prior work: `scratch/eta_research/sqlite_eta_effect/`, `scratch/eta_research/duckdb_connector/`
- LadybugDB C API: `kuzu.h`
- Arrow C data interface: `arrow.apache.org/docs/format/CDataInterface.html`
