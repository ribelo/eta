# Prior-art surface inventory

**Scope:** Top-level execution paths, builder shape, projection-to-record path,
tx carrier, expression compositionality, joins surface, raw-escape ergonomics,
migrate shape.

**Libraries:** Caqti, sqlx-Rust, Riot sqlx, Drizzle, Petrol.

---

## 1. Caqti (OCaml)

**Source:** `/home/ribelo/projects/github/caqti-oxcaml-2.3.0/caqti/lib/`

### Top-level execution paths
- One surface: `Caqti_connection_sig.S` (connection handle).
- Pooling is an orthogonal concern in subpackages (`caqti-eio`, `caqti-lwt`, etc.).
- No separate "pool execution" module — the connection sig exposes `exec`,
  `find`, `find_opt`, `collect_list`, `fold`, `with_transaction`.

### Builder shape
- **No runtime typed builder** for SELECT/INSERT/UPDATE/DELETE.
- Queries are SQL string templates with `?` placeholders.
- `Caqti_request.Infix` provides arrow operators (`->.`, `->!`, `->?`, `->*`)
  that attach param/row type descriptors to a query string.
- Dynamic query assembly: `Caqti_query.t` AST (literals, parameters, concat).

### Projection-to-record path
- Row types are **product descriptors**: `Caqti_type.tup2 int string`, etc.
- No automatic record mapping — tuples only.
- Manual record construction from tuples at call sites.

### Tx carrier
- `with_transaction : (unit -> ('a, 'e) result fiber) -> ('a, 'e) result fiber`
- Transaction is implicit scope, not an explicit handle passed to `tx_*` variants.
- No duplication of query API inside vs. outside tx.

### Expression compositionality
- N/A — expressions are raw SQL in strings. Caqti does not own expression syntax.

### Joins surface
- N/A — joins are written as raw SQL.

### Raw-escape ergonomics
- The **primary** path. No typed escape — everything is SQL string + params.
- `Caqti_query.t` provides safe parameter embedding (`P i`, `V (t, v)`) but
  no typed predicate combinators.

### Migrate shape
- Caqti does not ship migrations. Users typically write ad-hoc SQL scripts
  or use external tools (e.g. `omigrate`).

---

## 2. sqlx-Rust

**Source:** docs.rs/sqlx, web research.

### Top-level execution paths
- `sqlx::query!` macro (compile-time checked SQL).
- `sqlx::query_as!` macro (checked SQL + struct mapping).
- `sqlx::query()` / `query_as()` runtime functions (unchecked).
- `Pool`, `Transaction`, `Connection` — three types, but **one execution API**:
  `.fetch_one()`, `.fetch_all()`, `.fetch_optional()`, `.execute()` accept
  `&Pool`, `&mut Transaction`, or `&mut Connection` uniformly via `Executor` trait.

### Builder shape
- No runtime typed query builder for general SQL (the `query_builder` module
  exists but is limited compared to the macro path).
- The dominant idiom is **SQL-in-source** with `query!` / `query_as!`.

### Projection-to-record path
- `query_as!(StructName, "SELECT ...")` maps columns to struct fields by name.
- Order-independent mapping. Column types checked at compile time against DB.
- Partial projections: just select fewer columns; the macro checks compatibility.

### Tx carrier
- `let mut tx = pool.begin().await?;`
- `sqlx::query!(...).fetch_one(&mut *tx).await?` — same API, different executor.
- No `tx_*` prefix duplication; the `Executor` trait abstracts over pool/conn/tx.

### Expression compositionality
- N/A at the typed-builder level — expressions are SQL text inside macros.
- The macro does compile-time type inference of bind parameters and result columns.

### Joins surface
- Written as raw SQL inside `query!` / `query_as!`.
- Type-checked for column existence and type compatibility.

### Raw-escape ergonomics
- The primary path is raw SQL, but it is **compile-time checked**.
- The escape is ergonomic because the macro validates it.

### Migrate shape
- `sqlx::migrate!()` macro embeds migrations into the binary.
- `Migrator::run(pool)` applies pending migrations.
- Versioned by filename prefix (`1_create_users.sql`, `2_add_orders.up.sql`).

---

## 3. Riot sqlx

**Source:** `/home/ribelo/projects/github/riot/packages/sqlx/`

### Top-level execution paths
- **One surface:** `Sqlx.query : Pool.t -> string -> Value.t list -> (Cursor.t, error) result`
- `Sqlx.exec : Pool.t -> string -> Value.t list -> (int, error) result`
- `Sqlx.with_transaction : Pool.t -> (Connection.t -> ('a, error) result) -> ('a, error) result`
- No separate "typed builder" layer — raw SQL + param values only.

### Builder shape
- None. SQL is plain strings.

### Projection-to-record path
- `Cursor.t` provides row-by-row `Value.t` access.
- `Sqlx_driver.Row.int`, `.string`, etc. for manual field extraction.
- No automatic record/tuple mapping.

### Tx carrier
- Transaction is a scope callback receiving `Connection.t`.
- Same `Connection.query` / `Connection.execute` API inside tx.
- No `tx_*` duplication because there is no pool-level typed API to duplicate.

### Expression compositionality
- N/A — raw SQL.

### Joins surface
- N/A — raw SQL.

### Raw-escape ergonomics
- **100% escape rate** — there is no typed path.
- Ergonomics are "SQL string + `Value.t list`".

### Migrate shape
- `Sqlx.Migrate` with `run`, `run_to`, `undo`.
- Directory/file-based resolution (`1_xxx.sql`, `2_xxx.up.sql` / `2_xxx.down.sql`).
- SHA-256 checksums, dirty detection, version mismatch.
- Very close to Eta's `Migrate` — direct prior art.

---

## 4. Drizzle ORM (TypeScript)

**Source:** drizzle-team-drizzle-orm.mintlify.app

### Top-level execution paths
- One surface: `db.select()...from()...` returning a query object that can be
  executed with `await` or converted to SQL.
- No separate pool/connection/tx execution modules — the `db` object abstracts
  all of it.

### Builder shape
- **Full fluent typed builder**: `select`, `from`, `where`, `orderBy`, `limit`,
  `offset`, `groupBy`, `having`, `distinct`, `union`, `intersect`, `except`.
- Method chaining (`db.select().from(users).where(...).limit(10)`).

### Projection-to-record path
- Partial/selective projections via object literal:
  `db.select({ id: users.id, name: users.name })`.
- Full table projections via `db.select().from(users)`.
- Result is a typed object array, not tuples.

### Tx carrier
- `db.transaction(async (tx) => { ... })` — callback-scoped.
- Inside tx, `tx` supports the same API as `db`.
- No `tx_*` prefix duplication.

### Expression compositionality
- Rich: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `and`, `or`, `not`, `like`,
  `ilike`, `between`, `inArray`, `notInArray`, `isNull`, `isNotNull`.
- Arithmetic: `sql` template literal for arbitrary expressions.
- `CASE WHEN` via `sql` template.

### Joins surface
- `innerJoin`, `leftJoin`, `rightJoin`, `fullJoin`, `crossJoin`.
- Multiple joins chain naturally: `.from(users).innerJoin(posts, ...).leftJoin(comments, ...)`.
- Self-join via `alias()`.
- Lateral joins (`leftJoinLateral`) for PostgreSQL.
- Joined results are nested objects (`{ users: {...}, posts: {...} }`) or
  flattened with partial select.

### Raw-escape ergonomics
- `sql` template literal for raw SQL fragments with typed interpolation.
- Escape is ergonomic and composes with the builder.

### Migrate shape
- `drizzle-kit` handles migrations (separate CLI tool).
- Not part of the runtime query builder.

---

## 5. Petrol (OCaml)

**Source:** kiranandcode.github.io/petrol, ocaml.org/p/petrol

### Top-level execution paths
- One surface: `Petrol.exec`, `Petrol.find`, `Petrol.find_opt`,
  `Petrol.collect_list` — all take a Caqti connection (first-class module)
  and a compiled `Request.t`.
- No separate pool or tx module in Petrol itself — it delegates to Caqti.

### Builder shape
- Typed builder: `Query.select`, `Query.insert`, `Query.update`, `Query.delete`.
- Pipeline: `Query.select Expr.[...] ~from:table |> Query.where ... |> Query.order_by ...`.
- Query kind tracked via polymorphic variant (`[> `SELECT]`, etc.).

### Projection-to-record path
- Projections are `Expr.expr_list` (heterogeneous lists via GADT).
- `Query.select Expr.[id; name]` returns an `(int * string, _) query`.
- No automatic record-to-tuple mapping. Manual `let (id, name) = row`.

### Tx carrier
- Delegated to Caqti — `with_transaction` is Caqti's, not Petrol's.
- No `tx_*` duplication in Petrol because it has no pool-level execution API.

### Expression compositionality
- `Expr.eq`, `Expr.ne`, `Expr.gt`, `Expr.lt`, `Expr.like`, `Expr.between`,
  `Expr.in_`, `Expr.exists`.
- Arithmetic: `Expr.add`, `Expr.sub`, `Expr.mul`, `Expr.div`, `Expr.mod_`.
- Logical: `Expr.not`, `Expr.(&&)` (and), `(||)` (or).
- Aggregates: `Expr.count`, `Expr.sum`, `Expr.avg`, `Expr.min`, `Expr.max`.

### Joins surface
- `Query.join ?op ~on oexpr expr` where `op` is `LEFT | RIGHT | INNER`.
- The join appends a subquery/table to a select query.
- Supports joining a `(_, [> `SELECT_CORE | `SELECT ]) query` to another query.
- No explicit N-table chaining example in docs, but the type signature
  `('c, 'a) t -> ('c, 'a) t` suggests it can pipeline.

### Raw-escape ergonomics
- No explicit raw escape in the typed builder. If a query can't be expressed,
  users fall back to Caqti's raw SQL string templates.
- The escape path is through Caqti, which is well-documented.

### Migrate shape
- `VersionedSchema` for schema evolution.
- Not a file-based migration runner like Riot sqlx / Eta Migrate.

---

## Cross-tab summary

| Dimension | Caqti | sqlx-Rust | Riot sqlx | Drizzle | Petrol |
|---|---|---|---|---|---|
| **Top-level execution paths** | 1 (connection) | 1 (Executor trait over Pool/Conn/Tx) | 1 (Pool.query/exec) | 1 (db object) | 1 (Petrol.exec/find/...) |
| **Builder shape** | None — SQL strings + request arrows | None — SQL macros / raw strings | None — raw strings | Full fluent builder | Typed pipeline builder |
| **Projection-to-record** | Tuples via `Caqti_type.tupN` | Structs via `query_as!` | Manual Row helpers | Object literals (records) | Heterogeneous expr_list (tuples) |
| **Tx carrier** | `with_transaction` callback | `Transaction` executor | `with_transaction` callback | `db.transaction` callback | Delegated to Caqti |
| **Expression compositionality** | N/A (raw SQL) | N/A (raw SQL) | N/A (raw SQL) | Rich (`eq`, `gt`, `and`, `between`, `inArray`, etc.) | Good (`eq`, `between`, `in_`, `exists`, arith) |
| **Joins surface** | N/A (raw SQL) | N/A (raw SQL) | N/A (raw SQL) | Rich (`innerJoin`, `leftJoin`, `fullJoin`, `crossJoin`, chainable) | `Query.join` with `LEFT/RIGHT/INNER` |
| **Raw-escape ergonomics** | Primary path (safe params) | Primary path (compile-time checked) | Only path (SQL + Value list) | `sql` template (composable) | Fallback to Caqti raw strings |
| **Migrate shape** | None (external) | `migrate!` macro + `Migrator::run` | File-based (`run`, `run_to`, `undo`) | `drizzle-kit` CLI | `VersionedSchema` (not file-based) |

---

## Observations relevant to Eta Sql hypotheses

### H1 (Joins)
- Petrol has `Query.join` with LEFT/RIGHT/INNER, but the API is less ergonomic
  than Drizzle's chainable `.innerJoin().leftJoin()`.
- No OCaml prior art (Caqti, Petrol, Riot sqlx) demonstrates N≥3-table joins
  with the elegance of Drizzle or sqlx-Rust's raw SQL.
- This means H1's disproof signature (">2× LOC vs sqlx-Rust or Caqti") is a
  high bar — Caqti doesn't even have a typed join path to compare LOC against.
  The real comparison for H1 is "Eta typed path vs. raw SQL escape" within Eta.

### H2 (Expressions)
- Petrol has `between`, `in_`, `exists`, arithmetic, and logical operators.
- Eta's `Expr` is missing: `between`, col-vs-col arithmetic (`col1 < col2 + 5`),
  `IN (lit, lit, lit)` (only `in_select` exists), `CASE WHEN`.
- Petrol proves these are expressible in OCaml-side typed builders.

### H3 (Record projections)
- Neither Caqti nor Petrol auto-map to records. sqlx-Rust does via `query_as!`.
- Drizzle does via object literals. Eta's `Projection.map` is the manual bridge.
- The gap is real: no OCaml prior art solves this without PPX or manual mapping.

### H4 (Aggregations)
- Petrol has `count`, `sum`, `avg`, `min`, `max`. Drizzle has all plus
  `countDistinct`.
- Eta has `count`, `sum_int`, `row_number`. Missing: `avg`, `min`, `max`.
- Aggregate-vs-aggregate `HAVING` is expressible in all builders that have
  `having` (Drizzle, Petrol, Eta) provided the aggregate can be referenced.
  In Eta, `having` takes an `Expr.t`, but `Expr` lacks aggregate constructors
  that can be used in `HAVING` (only `count_ge`, `count_gt`, etc. exist).

### H5 (Subqueries)
- Petrol has `Expr.in_` and `Expr.exists`. Eta has `Expr.in_select` and
  `Expr.exists`.
- Correlated subqueries: Petrol's `exists` takes a query; Eta's `exists` takes
  a `Compiled.select`. Both can express it if the inner query references
  outer columns via the builder. Eta's `Select` builder doesn't expose a way
  to bind outer columns in a subquery, so correlation may require raw SQL.
- Drizzle supports correlated subqueries naturally in `exists` / `notExists`.

### H6 (Surface fragmentation)
- All prior art ships 1 execution surface (Caqti: connection; sqlx: Executor trait;
  Drizzle: db object; Petrol: delegated to Caqti).
- Eta is the outlier with 3: `Connection`, `Pool`, `Eta_pool`.
- Riot sqlx has `Connection` and `Pool`, but `Sqlx.query` operates on `Pool` only;
  the `Connection` module is for tx callbacks.

### H7 (Tx duplication)
- Prior art solves this with a unified carrier (Caqti callback, sqlx Executor trait,
  Drizzle tx callback, Petrol delegates to Caqti).
- Eta's `tx_*` prefix is unique among the surveyed libraries.

### H8 (Per-call kwargs)
- sqlx-Rust: pool-level timeouts configured on pool; per-query overrides via
  `.fetch_one(...)` with statement timeout.
- Drizzle: no per-call timeout in the builder — handled by the driver/DB.
- Caqti: connection-level `set_statement_timeout`.
- Eta's `~blocking_pool` and `~timeout` on every call is unusual. No prior art
  requires both on every operation.

### H9 (Migrate right-sizing)
- Riot sqlx Migrate is the direct prior art. It has `list_applied`, `run`,
  `run_to`, `undo`, and similar error variants.
- Eta Migrate mirrors this closely. The question is whether the mirror is
  over-complete (e.g., `undo` may not be exercised).

### H10 (Raw escape rate)
- Caqti and Riot sqlx: 100% raw SQL (by design).
- sqlx-Rust: ~100% raw SQL, but compile-time checked.
- Drizzle: <10% escape rate for typical CRUD; complex analytics may use `sql`.
- Petrol: moderate escape rate — complex queries fall back to Caqti strings.
- Eta's target should be Drizzle-like low escape for common workloads.
