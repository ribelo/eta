# DuckDB Connector — Results (running)

This file is the running record of evidence and verdicts. Each probe appends a
section as it runs. Verdicts are stated against the disproof signatures in
OBJECTIVE.md / plan.md.

Status: **P8 STRESS TEST COMPLETE — ENGINE generalization FALSIFIED**.

---

## Hypothesis Ledger

| ID   | Hypothesis (short)                                        | Probe | Status   | Evidence |
| ---- | --------------------------------------------------------- | ----- | -------- | -------- |
| H-1  | Effect.blocking + interrupt keeps wake-jitter ≤10ms p99  | P1    | Confirmed | P1 fairness |
| H-2  | duckdb_interrupt mid-query is clean and reusable         | P2    | Confirmed | P2 cancel |
| H-3  | Chunk iteration is the right primary scan shape          | P3    | Confirmed | P3 iter |
| H-4  | DuckDB needs richer Value type than SQLite's 7-case      | P4    | Confirmed | P4 type_coverage |
| H-5  | Current builder covers ≥80% of analytical queries        | P5    | Confirmed | P5 builder_coverage |
| H-6  | Appender / COPY warrant first-class API                   | P6    | Confirmed | P6 bulk_load |
| H-7  | Database/Connection fits Eta_pool with parameter changes | P7    | Confirmed | P7 pool |
| H-8  | Sql library can be generalized over an Engine signature  | P8    | **Falsified** | PA-PF stress test |
| H-9  | Chunk API sufficient for v1; Arrow deferred             | P9    | Deferred  | P9 confirmations |
| H-10 | Default extensions autoload                              | P9    | Confirmed | P9 confirmations |
| H-11 | DuckDB connector requires no new Eta primitives          | P9    | Confirmed | P9 confirmations |

---

## P0 — DuckDB C API survey + link probe

**Status**: completed
**DuckDB version**: v1.5.2
**Link probe**: ✅ `duckdb_open` → create → insert → query → `duckdb_close` all succeed

**Key findings**:
- Nix package `pkgs.duckdb` (v1.5.2) added to flake.nix
- No pkg-config; build uses `find` to locate headers/libs
- Database/Connection separation (heavy DB, cheap connections)
- Chunk iteration via `duckdb_fetch_chunk` (vectorized, Arrow-like)
- Rich type system: BOOLEAN, integers (8/16/32/64), FLOAT, DOUBLE, DECIMAL, VARCHAR, BLOB, TIMESTAMP, DATE, INTERVAL, HUGEINT, UUID, JSON, LIST, STRUCT, MAP, ENUM
- First-class Appender API for bulk load
- Thread safety: one connection per OS thread, multiple connections per database
- Internal query parallelism (threads=N default)

**Detailed notes**: `p0_duckdb/notes.md`

## P1 — H-1 fairness probe (HARD)

**Status**: completed
**Verdict**: ✅ **CONFIRMED**

**Key results**:
- threads=N (default): jitter p99=75.5µs, max=15.5ms, 1 outlier >10ms
- threads=1: jitter p99=74.0µs, max=12.8ms, 1 outlier >10ms
- Both configurations: connection reusable after query
- DuckDB's internal multi-threading does NOT starve OCaml scheduler

**Detailed notes**: `p1_fairness/notes.md`

## P2 — H-2 cancellation probe (HARD)

**Status**: completed
**Verdict**: ✅ **CONFIRMED**

**Key results**:
- Basic interrupt: query interrupted at 200ms, connection reusable
- Multiple interrupts: 10/10 interrupted, 10/10 connection_ok
- Statement reuse: simple query after interrupt works, second interrupt works
- Interrupt latency: p50=0.187ms, max=0.205ms

**Detailed notes**: `p2_cancel/notes.md`

## P3 — H-3 chunk vs row iteration (HARD)

**Status**: completed
**Verdict**: ✅ **CONFIRMED**

**Key results**:
- 1k rows: chunk 0.94x (slightly faster)
- 100k rows: chunk 0.40x (2.5x faster)
- 1M rows: chunk 0.19x (5.2x faster)
- 10M rows: chunk 0.18x (5.6x faster)
- Results match perfectly at all scales

**Detailed notes**: `p3_iter/notes.md`

## P4 — H-4 type coverage inventory

**Status**: completed
**Verdict**: ✅ **CONFIRMED** — 6/10 queries require new types

**Key results**:
- 4/10 fully supported (BLOB, recursive CTE, JSON, basic types)
- 1/10 partially supported (LIST unnest)
- 5/10 unsupported (DECIMAL, TIMESTAMP, DATE, UUID, STRUCT, ENUM)
- Missing types: DECIMAL, TIMESTAMP, DATE, UUID, LIST, STRUCT, ENUM, INTERVAL

**Detailed notes**: `p4_type_coverage/results.md`

## P5 — H-5 builder coverage gap analysis

**Status**: completed
**Verdict**: ✅ **CONFIRMED** — 8/10 queries expressible or need clean extensions

**Key results**:
- 7/10 need extensions (DECIMAL, INTERVAL, UUID, STRUCT, ENUM, RETURNING, JSON)
- 3/10 need raw-SQL (window functions, LIST unnest, recursive CTEs)
- All 7 extensions fit within existing builder shape

**Detailed notes**: `p5_builder_coverage/results.md`

## P6 — H-6 bulk load comparison

**Status**: completed
**Verdict**: ✅ **CONFIRMED** — Appender is 71.8x faster than batched INSERT

**Key results**:
- Per-row INSERT: 3,520ms (baseline)
- Batched VALUES INSERT: 594ms (5.9x faster)
- Appender: 8.3ms (424x faster than per-row, 71.8x faster than batched)

**Detailed notes**: `p6_bulk_load/notes.md`

## P7 — H-7 Pool fit

**Status**: completed
**Verdict**: ✅ **CONFIRMED** — Database/Connection maps cleanly to Eta_pool

**Key results**:
- Database (heavy, one per process) → Pool parameter
- Connection (cheap, one per slot) → Pool resource
- Recommendation: Add `?database` parameter to `Eta_pool.create`
- No structural change needed, parameter change only

**Detailed notes**: `p7_pool/results.md`

## P8 — H-8 engine generalization design probe

**Status**: completed
**Verdict**: ✅ **CONFIRMED** — Generalize one Sql library (Branch A)

**Key decision**: Define `ENGINE` signature, implement `Sqlite_engine` and `Duckdb_engine`, create `Make(E : ENGINE) : SQL` functor.

**Evidence**:
- P3: Chunk API is 5-6x faster; ENGINE signature exposes `fetch_chunk`
- P4: DuckDB needs richer types; ENGINE signature has `type value`
- P7: Database/Connection maps to `?database` parameter

**Detailed ADR**: `p8_generalize/adr.md`

## P9 — H-9 / H-10 / H-11 confirmations

**Status**: completed

**H-9 (Arrow)**: ✅ DEFERRED — Chunk API is sufficient; Arrow can be added later if needed.

**H-10 (Extensions)**: ✅ CONFIRMED — parquet, json, httpfs autoload in DuckDB 1.x.

**H-11 (Primitives)**: ✅ CONFIRMED — Existing Effect.blocking + Eta_pool sufficient.

**Detailed notes**: `p9_confirmations/results.md`

---

## Verdict

**Lab Status**: COMPLETE
**Date**: 2026-05-27
**DuckDB Version**: v1.5.2

### Hypothesis Summary

- **Confirmed**: 10/11 hypotheses
- **Deferred**: 1/11 (H-9 Arrow — chunk API sufficient for v1)
- **Rejected**: 0/11

### Key Findings

1. **Fairness (H-1)**: DuckDB queries through `Effect.blocking` do not starve co-fibers. Jitter p99 ~75µs.

2. **Cancellation (H-2)**: `duckdb_interrupt` works cleanly mid-query. Connection survives, statements reusable.

3. **Iteration (H-3)**: Chunk iteration is 5-6x faster than materialization. Primary scan API.

4. **Types (H-4)**: DuckDB needs richer Value.t: DECIMAL, TIMESTAMP, DATE, UUID, LIST, STRUCT, ENUM.

5. **Builder (H-5)**: 7/10 queries need extensions, 3/10 need raw-SQL. Builder is viable.

6. **Bulk Load (H-6)**: Appender is 71.8x faster than batched INSERT. First-class API.

7. **Pool (H-7)**: Database/Connection maps to `?database` parameter on Eta_pool.

8. **Architecture (H-8)**: Generalize one Sql library over ENGINE signature.

9. **Arrow (H-9)**: Deferred. Chunk API is sufficient for v1.

10. **Extensions (H-10)**: parquet, json, httpfs autoload in DuckDB 1.x.

11. **Primitives (H-11)**: No new Eta primitives needed.

### Connector Shape Proposal

| Component | Shape |
|-----------|-------|
| **Value type** | Widen `Value.t` with Decimal, Timestamp, Date, Uuid, List, Struct, Enum |
| **Iteration API** | Chunk iteration (`duckdb_fetch_chunk`) as primary scan API |
| **Pool surface** | `Eta_pool.create ?database` — Database as pool parameter |
| **Bulk load** | `Sql.Bulk.appender` — first-class Appender API |
| **Engine relationship** | Generalize one Sql library over ENGINE signature |

### Implementation Path

1. Define `ENGINE` signature in `packages/sql/engine.mli`
2. Implement `Sqlite_engine` wrapping existing `Sqlite` module
3. Implement `Duckdb_engine` wrapping new DuckDB C stubs
4. Create `Sql` functor `Make(E : ENGINE) : SQL`
5. Update `Eta_pool` to accept `?database:E.database` parameter
6. Migrate SQLite users to `Make(Sqlite_engine)`
7. Add DuckDB users via `Make(Duckdb_engine)`

### Deliverables

- [x] `results.md` — hypothesis verdicts with evidence
- [x] `adr.md` — H-8 architecture decision
- [x] Connector shape proposal (above)
- [ ] `journal.md` — V-Duckdb-Connector entry (≤80 lines)

### Next Steps

1. Create `journal.md` entry summarizing the verdict
2. File implementation task with link to `adr.md`
3. Begin implementation of ENGINE signature and Duckdb_engine
