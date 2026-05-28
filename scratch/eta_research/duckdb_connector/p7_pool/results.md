# P7 — DuckDB Pool Fit Analysis

**Status**: completed
**Hypothesis H-7**: DuckDB's Database-then-Connection lifetime model fits Eta_pool with parameter changes only.
**Verdict**: ✅ **CONFIRMED** — Database/Connection separation maps cleanly to Eta_pool.

## DuckDB Lifetime Model

```
Database (heavy, one per process/file)
  └── Connection (cheap, one per fiber/pool-slot)
        └── PreparedStatement (per query)
              └── Result (per execution)
```

### Key Properties

1. **Database is heavy**: `duckdb_open()` loads extensions, initializes storage, acquires file locks.
2. **Connection is cheap**: `duckdb_connect()` is a lightweight handle to the Database.
3. **Multiple connections per Database**: Intended pattern for concurrent access.
4. **Thread safety**: One connection per OS thread; multiple connections per Database.

## Current Eta_pool Shape

From `packages/eta/pool.mli`:
```ocaml
type 'a t

val create :
  ?max_size:int ->
  ?acquire_timeout:Duration.t ->
  (unit -> 'a) ->
  ('a -> unit) ->
  'a t

val with_resource :
  ?timeout:Duration.t ->
  'a t ->
  ('a -> 'b) ->
  'b
```

### Current Usage (SQLite)

```ocaml
(* SQLite: one connection per pool slot *)
let pool = Sql.Eta_pool.create config
(* Internally: *)
(* - acquire: opens a new sqlite3 connection *)
(* - release: closes the sqlite3 connection *)
```

## DuckDB Pool Mapping

### Option A: Database as Pool Parameter (Recommended)

```ocaml
(* DuckDB: Database shared across pool, Connection per slot *)
let pool = Sql.Eta_pool.create ~database:db config
(* Internally: *)
(* - acquire: duckdb_connect(db) → new connection *)
(* - release: duckdb_disconnect(conn) → close connection *)
```

**Pros**:
- Database created once, shared across all pool slots
- Clean separation: heavy initialization vs lightweight per-slot
- Matches DuckDB's intended usage pattern

**Cons**:
- Requires adding `~database` parameter to `Eta_pool.create`
- Breaking change for existing SQLite users (but SQLite doesn't need it)

### Option B: Database as Closure State

```ocaml
(* DuckDB: Database captured in closure *)
let db = D.open_memory () in
let pool = Sql.Eta_pool.create
  ~acquire:(fun () -> D.connect db)
  ~release:(fun conn -> D.disconnect conn)
  config
```

**Pros**:
- No API change to Eta_pool
- Database lifetime managed by user code
- Works with existing pool shape

**Cons**:
- User must manage Database lifetime manually
- No built-in cleanup on pool shutdown

### Option C: Database as Pool Lifecycle Hook

```ocaml
(* DuckDB: Database as lifecycle hook *)
let pool = Sql.Eta_pool.create
  ~init:(fun () -> D.open_memory ())
  ~acquire:(fun db -> D.connect db)
  ~release:(fun conn -> D.disconnect conn)
  ~shutdown:(fun db -> D.close_db db)
  config
```

**Pros**:
- Full lifecycle management
- Clean shutdown closes Database after all connections
- No breaking change to existing API

**Cons**:
- More complex API
- Overkill for SQLite (which has no Database/Connection separation)

## Recommendation

**Option A (Database as Pool Parameter)** is the cleanest fit:

1. **Add `?database` parameter**: `Eta_pool.create ?database ...`
2. **SQLite ignores it**: SQLite connections don't need a Database handle
3. **DuckDB uses it**: DuckDB connections are created from the Database

This is a **parameter change only**, not a structural change to Eta_pool.

## Fanout Verification

The P1 fairness probe already verified concurrent connection behavior:
- 16 heartbeat threads ran concurrently
- Each thread used a separate connection to the same Database
- No connection leaks or corruption

## Implications for Connector Design

- **Database created once**: `Sql.Duckdb.open_database ~path ...`
- **Pool uses Database**: `Sql.Eta_pool.create ~database:db ...`
- **Connections pooled**: Each fiber gets a connection from the pool
- **Clean shutdown**: Pool closes connections, then Database

## Next Steps

H-7 is confirmed. Proceed to **P8** (engine generalization design probe) — the architectural pivot.
