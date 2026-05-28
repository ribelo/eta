# DuckDB Connector — Detailed Probe Plan

This document is the per-probe specification. It complements the high-level
hypothesis ledger in OBJECTIVE.md with concrete fixture shapes, measurement
points, and pass/fail thresholds.

The experimenter starts with P0, runs P1 / P2 / P3 in order (hardest-first),
and only proceeds to P4–P9 if the load-bearing probes pass. The H-8
generalization probe (P8) consumes the outputs of P3 / P4 / P7.

---

## P0 — DuckDB C API Survey + Link Probe

**Goal**: confirm DuckDB is reachable from OCaml via direct C stubs and
identify the C API entry points the connector will use. No falsifier; this
unblocks P1.

### Fixture

`p0_duckdb/p0_link_probe.ml` + `p0_duckdb/p0_duckdb_stubs.c` + `dune` mirroring
`scratch/eta_research/sqlite_fast/p0_link_probe.ml`. The C stub calls
`duckdb_library_version()` and runs a one-row query against an in-memory
Database.

### Output

`p0_duckdb/notes.md` listing:

- DuckDB version reported by `duckdb_library_version()`;
- pkg-config status (`pkg-config --modversion duckdb`);
- entry points the connector will use, grouped:
  - lifecycle: `duckdb_open`, `duckdb_open_ext`, `duckdb_close`,
    `duckdb_connect`, `duckdb_disconnect`;
  - prepare/bind/execute: `duckdb_prepare`, `duckdb_bind_*`,
    `duckdb_execute_prepared`, `duckdb_destroy_prepare`;
  - chunked results: `duckdb_fetch_chunk`, `duckdb_data_chunk_get_vector`,
    `duckdb_vector_get_data`, `duckdb_vector_get_validity`,
    `duckdb_destroy_data_chunk`;
  - cancellation: `duckdb_interrupt`;
  - errors: `duckdb_result_error`, `duckdb_query_progress`;
  - bulk load: `duckdb_appender_create`, `duckdb_append_*`,
    `duckdb_appender_close`, `duckdb_appender_destroy`;
  - introspection: `duckdb_column_count`, `duckdb_column_type`,
    `duckdb_column_name`.
- thread-safety notes from the C API documentation (one Connection per
  thread; multi-Connection per Database).

### Flake update

If `pkgs.duckdb` is not in the current flake, add it. Coordinate the change so
it lands on master before any probe execution. Document the version pin
inline.

---

## P1 — H-1 Fairness Probe (HARD)

**Hypothesis**: `Effect.blocking ?on_cancel:duckdb_interrupt` keeps co-fiber
wake-jitter ≤10ms p99 during a 30-second OLAP query.

### Fixture

`p1_fairness/duckdb_fairness_probe.ml`:

1. Setup: in-memory DuckDB Database. Build a synthetic table `t(a BIGINT,
   b VARCHAR, c DOUBLE)` populated with 1M rows of random data via Appender or
   `range`-table generator (`INSERT INTO t SELECT * FROM range(1000000) ...`).
2. Workload: a query that takes ~30 seconds with `threads=1`. Candidate:
   `SELECT a % 100 AS bucket, AVG(c) FROM t CROSS JOIN range(50) GROUP BY bucket`
   (force enough work to dominate). Tune row count / cross-join factor until
   the chosen workload reliably runs ≥30s with `threads=1` and ≥5s with
   `threads=N`.
3. Co-fibers: 16 fibers in the same Eio domain, each ticking every 1ms via
   `Effect.delay`. Each tick records `Mtime.now()`; jitter = actual elapsed
   minus 1ms.
4. Run the OLAP query under `Effect.blocking ?on_cancel:duckdb_interrupt`
   while co-fibers tick.
5. Run twice: with `threads=N` (no SET) and with `SET threads=1` issued before
   the query.

### Measurements

- Co-fiber wake-jitter: p50, p95, p99, max, count of >10ms outliers.
- Query wall-time.
- For comparison: re-run the SQLite F-Block fixture if needed, or cite
  `scratch/eta_research/sqlite_eta_effect/results.md` line numbers.

### Pass / Fail

**Pass**: p99 wake-jitter ≤10ms in both `threads=N` and `threads=1` modes.

**Fail**: p99 >10ms in either mode. Stop the lab; the connector shape needs
re-evaluation (probably a per-connection worker thread, parallel to the SQLite
C-option that was rejected — but DuckDB might force it back into the menu).

### Output

`p1_fairness/results.md` with the raw output, the jitter histogram, and a
verdict line.

---

## P2 — H-2 Cancellation Probe (HARD)

**Hypothesis**: `duckdb_interrupt` mid-query returns DUCKDB_INTERRUPTED, the
OCaml call returns within the timeout grace window, the connection passes a
follow-up `SELECT 1`, and a prepared statement that was interrupted can be
re-bound and re-executed.

### Fixture

`p2_cancel/duckdb_cancel_probe.ml`:

1. Setup: same synthetic table as P1, query that takes ≥10 seconds.
2. Variant A — `Effect.timeout`: issue the query under
   `Effect.timeout ~deadline:(Duration.ms 100)`. Verify the call returns
   within ≤500ms. Verify `connection.query "SELECT 1"` succeeds.
3. Variant B — `Supervisor.scoped` cancel: fork the query in a Supervisor
   scope; cancel after 100ms. Same checks.
4. Variant C — prepared statement reuse: prepare a long query, bind, execute,
   interrupt at 100ms, then `bind` new params and re-execute. Must succeed.
5. Variant D — interrupt at the chunk boundary vs interrupt mid-chunk: time
   the interrupt-to-return latency for both. Document any latency floor.

### Measurements

- Time from interrupt call to OCaml call returning, p50 / p99 / max.
- Connection survival rate (over 100 cycles): % that pass `SELECT 1`.
- Statement reuse rate (over 100 cycles): % that re-bind + re-execute
  successfully.

### Pass / Fail

**Pass**: connection survival ≥99%, statement reuse ≥99%, interrupt latency
p99 ≤500ms in all variants.

**Fail**: connection corruption observed, OR interrupt is statement-boundary
only (cannot kill mid-query), OR statement re-execute fails after interrupt.
Stop and re-evaluate cancellation strategy.

### Output

`p2_cancel/results.md`.

---

## P3 — H-3 Chunk vs Row Iteration (HARD)

**Hypothesis**: chunk-native iteration via `duckdb_fetch_chunk` is the right
primary scan shape; per-row API is unnecessary; chunk per-row allocation does
not exceed SQLite's row-step floor by >2×.

### Fixture

`p3_iter/duckdb_iter_probe.ml`:

1. Setup: synthetic table 10M rows, 3 columns (BIGINT, VARCHAR (small),
   DOUBLE).
2. Strategy A — full materialize: `duckdb_query`, iterate the result via the
   row-at-a-time deprecated API (or by walking chunks but copying into an
   `array`). Sum the BIGINT column; this is the workload.
3. Strategy B — chunk iterate: `duckdb_fetch_chunk` loop, sum BIGINT directly
   from the chunk's vector data.
4. Strategy C — per-row (if exposed): use the `duckdb_value_*` row-by-row API
   on a streaming result.
5. Vary result size: 1k / 100k / 1M / 10M rows.

### Measurements

- Wall-time (median of 5 runs).
- `Gc.minor_words`, `Gc.major_words`, `Gc.promoted_words` deltas.
- Peak RSS (read `/proc/self/status` `VmHWM`).
- Per-row floor: total alloc / row count.

### Pass / Fail

**Pass for H-3**: B beats A on wall-time at all scales ≥100k rows AND B's
per-row alloc ≤2× SQLite's per-row floor (cite the SQLite F-Floor number from
`sqlite_eta_effect/results.md`).

**Fail**: A wins on wall-time at any scale ≤10M rows, OR B's alloc is
disqualifying.

### Output

`p3_iter/results.md` with the alloc + wall-time table per strategy per scale.

---

## P4 — H-4 Type Coverage Inventory

**Hypothesis**: SQLite's closed `Value.t` (Null/Int/Int64/Float/String/Bool/Bytes)
is insufficient for the anchor workload.

### Fixture

`p4_type_coverage/workload_profile.md` (write first) lists 10 representative
queries drawn from the embedded analytical store anchor. Each query has:

- a schema snippet declaring the columns it touches (with DuckDB types);
- the query text;
- expected parameter types and result column types.

Suggested mix:

1. DECIMAL aggregation — `SELECT SUM(price) FROM orders WHERE region = ?` where
   `price DECIMAL(18,4)`.
2. TIMESTAMP_TZ window — rolling 7-day average over events with
   `event_at TIMESTAMPTZ`.
3. DATE + INTERVAL filter — `WHERE created_at >= ? - INTERVAL '30 days'`.
4. UUID primary key join across two tables.
5. LIST unnest — `SELECT id, unnest(tags) FROM products`.
6. STRUCT field access — `WHERE address.city = ?`.
7. ENUM filter — `WHERE status = 'active'::status_enum`.
8. BLOB roundtrip — write a 4KB blob, read back, verify equal.
9. Recursive CTE — hierarchy traversal.
10. JSON extract — `SELECT data->>'name' FROM events`.

For each, attempt to:

- bind parameters using the current `Sql.Value.t`;
- decode results using `Sql.Row.get` / column extractors.

Mark each: `Lossless` / `Lossy-via-string` / `Unsupported`.

### Output

`p4_type_coverage/results.md` with the matrix and a sketch of two widening
shapes:

- **Widen `Sql.Value.t`** — add cases (`Decimal of {value : int64; scale : int}`,
  `Timestamp_tz of int64` (microseconds since epoch), `Uuid of bytes` (16 bytes),
  `List of t list`, `Struct of (string * t) list`, `Enum of int * string`).
  Note: this is breaking-ish for `Row.get` decoders.
- **Engine-specific Value type** — `Sql.Engine.Sqlite.Value` vs
  `Sql.Engine.Duckdb.Value`, with the typed `'a typ` GADT bridging both.

This output feeds P8 (engine generalization).

---

## P5 — H-5 Builder Coverage Gap Analysis

**Hypothesis**: the current `Sql.Select` / `Insert` / `Update` / `Delete`
builders cover ≥80% of analytical queries; the tail extends cleanly without
restructuring scope/projection types.

### Fixture

Take the same 10 queries from P4. Express each in the current typed builder.
Mark each:

- **Expressible** (record the combinators used);
- **Extension-needed** (sketch the extension; e.g.,
  `Expr.window ~partition_by ~order_by`, `Source.asof_join`, `Expr.list_index`,
  `Expr.struct_field`, `Select.qualify`);
- **Raw-SQL required** (document the construct that cannot be hosted, e.g.,
  PIVOT/UNPIVOT macros, full named WINDOW clause, complex SET-RETURNING
  functions).

### Output

`p5_builder_coverage/results.md` with the 10-query expression table and a
proposed extension surface for the "tail" constructs.

### Pass / Fail

**Pass for H-5**: ≥8/10 expressible or extension-needed (clean fit).

**Fail**: >2/10 raw-SQL-required because the builder shape cannot host the
construct. This is a major signal for H-8 — the builder may be too
SQLite-shaped.

---

## P6 — H-6 Bulk Load Comparison

**Hypothesis**: Appender / `COPY FROM` warrant first-class API; the per-row
INSERT path is wrong-shaped for bulk ingestion.

### Fixture

`p6_bulk_load/duckdb_bulk_probe.ml`. Insert 1M synthetic rows three ways:

- **A: per-row INSERT** in a single transaction.
- **B: batched VALUES INSERT** (1000 rows per statement).
- **C: Appender** via direct `duckdb_appender_*` stubs.

Optional **D: COPY FROM** a pre-written CSV file (secondary workload).

### Measurements

- Wall-time per strategy.
- Total minor + major words allocated.

### Pass / Fail

**Pass for H-6**: C beats B by ≥2×.

**Fail**: C beats B by <2×; the Appender surface does not earn its place. In
that case, mark Appender as `Deferred` and let bulk users batch INSERTs.

### Output

`p6_bulk_load/results.md` with timings and (if H-6 confirmed) a sketch of
`Sql.Bulk.appender` / `Sql.Bulk.copy_from` API.

---

## P7 — H-7 Pool Fit

**Hypothesis**: DuckDB's Database-then-Connection lifetime model fits Eta_pool
with parameter changes only.

### Fixture

`p7_pool/duckdb_pool_probe.ml`:

1. Open a single Database (heavy, once).
2. Use `Eta_pool.create` with a custom `acquire`/`release` that takes the
   Database and returns a Connection from `duckdb_connect`.
3. Fanout fixture: 16 fibers, pool size 4, each runs a 5-second query.
4. Verify: pool fairness, no leaked Connections, clean shutdown closes
   Connections then Database.

### Measurements

- Pool fairness (acquire wait p50 / p99).
- Leaked Connections after shutdown (must be 0).
- Database close ordering (must be after all Connections).

### Pass / Fail

**Pass for H-7**: parameter changes only (defaults like `acquire_timeout`,
`max_connections`); no structural change to `Eta_pool`.

**Fail**: needs a `~database:Database.t` argument or new lifecycle hook. File
as a separate primitive task (H-11 falsified).

### Output

`p7_pool/results.md`.

---

## P8 — H-8 Engine Generalization Design Probe

**Hypothesis**: the `Sql` library can be generalized over an Engine signature
without complicating SQLite call sites.

### Fixture

Paper-sketch + minimal mock-signature lab. Two branches:

- **Branch A — generalize**: in `p8_generalize/branch_a_engine_sig.ml`, sketch
  `module type ENGINE = sig type db type stmt type chunk type value ... end`
  with all engine-specific operations. Show `module Sqlite_engine : ENGINE`
  and `module Duckdb_engine : ENGINE`. Show how the typed builder
  (`Compiled.select`, `Eta_pool`) depends on Engine — functor or first-class
  module or no-dependency-at-all.
- **Branch B — split**: in `p8_generalize/branch_b_split.ml`, sketch a shared
  `Sql_typed` library with the typed builder (engine-neutral) and two
  consumer libraries `Sql_sqlite` / `Sql_duckdb` each owning their own
  Connection / Pool / Eta_pool. Document the duplication.

### Compare on

- Consumer call-site: write a sample analytical query end-to-end in both shapes
  (open Database → run typed select → fold rows). Compare LOC and clarity.
- Error type: does the generalized error preserve SQLite's `Sqlite.error`
  structure and DuckDB's structured error cleanly, or does it muddle?
- Allocation: does Engine indirection add boxing per call (functor overhead,
  first-class module dispatch)?
- Migration cost on existing SQLite users when Branch A lands. Any breaking
  signature?
- Carrying H-3 (chunk vs row), H-4 (Value type), H-7 (Pool shape) outcomes:
  which branch hosts them more cleanly?

### Output

`adr.md` with the verdict, evidence cites, and the dominated-branch
documentation. Status: `Confirmed` / `Rejected` / `Deferred` per the rules.

This is the architectural call of the lab.

---

## P9 — H-9 / H-10 / H-11 Confirmations

Cheap. Run together at the end.

- **H-9 Arrow**: confirm `duckdb_query_arrow` exists; one-paragraph deferral
  rationale citing the chunk API as sufficient for the anchor workload.
- **H-10 Extensions**: open a fresh Database, query
  `SELECT extension_name, loaded, installed FROM duckdb_extensions()`,
  confirm parquet / json / httpfs are loaded by default.
- **H-11 Primitive gap**: scan the closed P1–P8 results for any pattern that
  required a new Eta primitive. If yes, file as a separate task with its own
  reduced-scope plan; do not fold the primitive into the connector lab.

### Output

`results.md` final "verdict" section with the H-1 through H-11 ledger
finalized.

---

## Closing the Lab

When all probes have run and verdicts are recorded:

1. Update `adr.md` with the H-8 verdict and the connector-shape proposal
   (Value type, iteration, Pool, bulk-load, engine relationship).
2. Append a `V-Duckdb-Connector` entry to `journal.md` at the worktree root
   (≤80 lines): question, ledger, evidence, decision, would-change-if.
3. If H-11 falsified: file the primitive gap as its own task in master with a
   short reduced-scope research plan.
4. The implementation task is **not** part of this lab. File a separate
   implementation task (with link to `adr.md`) only after the lab closes.
