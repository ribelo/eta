# sql_dx lab

Research on the DX and capability ceiling of `lib/sql/`'s typed-builder
+ execution surface.

**Mode:** research only. No edits under `lib/`.

**Authoritative spec:** `../OBJECTIVE.md` at the worktree root.

## Layout

```
prior_art.md                  five-library cross-tab (Caqti, sqlx-Rust, Riot sqlx, Drizzle, Petrol)
workload_corpus.md            ~15 queries; plain SQL + intent + per-API expression notes
p1_joins/                     H1 — N≥3-table joins                    [load-bearing]
p2_expressions/               H2 — col-vs-col, arith, BETWEEN, CASE   [load-bearing]
p3_surface/                   H6 — three execution paths
p4_tx/                        H7 — tx_* duplication
p5_kwargs/                    H8 — mandatory ~blocking_pool / ~timeout
p6_records/                   H3 — structural row decode to records
p7_aggregations/              H4 — SUM/AVG/MIN/MAX, aggregate-vs-aggregate HAVING
p8_subqueries/                H5 — correlated, lateral, compositional EXISTS
p9_migrate_audit/             H9 — Migrate public-verb coverage
p10_raw_escape/               H10 — escape-to-raw rate over the corpus
results.md                    per-probe verdicts + captured run logs + surprise findings
adr.md                        verdict ((a)/(b)/(c) or mixed) with evidence trace
```

## Hypothesis ledger

Status discipline: every H is one of
`Active / Rejected / Dominated / Deferred / Out of scope / Accepted`.
Untested ≠ rejected. See `../OBJECTIVE.md §3` for full statements and
disproof signatures.

| ID | One-line claim | Status |
|---|---|---|
| H1 | N≥3-table joins compose without exponential nesting tax | Active |
| H2 | `Expr` is compositional enough for real predicates | Active |
| H3 | `Projection` decodes column subsets to records, not just tuples | Active |
| H4 | Aggregations cover real workloads (incl. aggregate-vs-aggregate HAVING) | Active |
| H5 | Subquery composition (correlated, lateral) carries real consumers | Active |
| H6 | Three execution surfaces (`Connection`/`Pool`/`Eta_pool`) deliver distinct value | Active |
| H7 | `tx_*` prefix duplication is forced by OCaml's type system | Active |
| H8 | Mandatory `~blocking_pool`/`~timeout` per call beats pool-default-with-override | Active |
| H9 | `Migrate` is right-sized | Active |
| H10 | Raw-query escape (`Value.t list`) is rare enough to ignore | Active |

## Probe order

P0 → P1 → P2 → P3 → P4 → P5 → P6 → P7 → P8 → P9 → P10

**Stop at falsifier:**
- P1 (H1) fail → halt; reshape ADR.
- P2 (H2) fail → halt; `Expr` reshape ADR.
- Other probes have independent verdicts; no halt cascade.

## Methodology

Per `../OBJECTIVE.md §9`:

1. No verdict without captured run log (`<probe>/run.log`).
2. No clean tables. Surprises and self-corrections are deliverables.
3. Steelman every hypothesis before testing. Disproof signature targets the
   strongest version, not a strawman.
4. Hardest-probe-first. P1 and P2 run before DX-shape probes.
5. Prior-art is calibration, not authority. Verdicts cite OCaml-side reasons.

## What this lab does not do

- Edit `lib/` — research only.
- Implement the reshape — that is a separate worktree picked up after this lab closes.
- Compare against engines beyond SQLite (DuckDB, Postgres, Turso are
  separate labs in `../Eta-duckdb`).
- Build the SQL-literal PPX (`[%sql.query "..."]`) — separately deferred.
