# P7 — Pool Fit Analysis

**Status**: completed (paper analysis)
**Hypothesis H-7**: Database/Connection fits Eta_pool with parameter changes only.
**Verdict**: ✅ **CONFIRMED** — Same model as SQLite.

## Turso Lifetime Model

Turso uses the same Database/Connection model as SQLite:

```
Database (sqlite3*, one per process/file)
  └── Connection (same as Database in SQLite)
        └── Statement (sqlite3_stmt*, per query)
```

### Key Properties

1. **Database = Connection**: In SQLite's C API, `sqlite3*` serves as both Database and Connection.
2. **Thread safety**: One `sqlite3*` per thread (same as SQLite).
3. **No separate Connection object**: Unlike DuckDB, SQLite/Turso don't have a separate Connection concept.

## Current Eta_pool Shape (SQLite)

```ocaml
let pool = Sql.Eta_pool.create config
(* Internally: *)
(* - acquire: opens a new sqlite3 connection *)
(* - release: closes the sqlite3 connection *)
```

## Turso Pool Mapping

Turso uses the same pool model as SQLite:

```ocaml
(* Turso: same as SQLite *)
let pool = Sql.Eta_pool.create ~encryption_key:"..." config
(* Internally: *)
(* - acquire: sqlite3_open + sqlite3_key (if encryption) *)
(* - release: sqlite3_close *)
```

### No Structural Change Needed

- **Same pool shape**: Turso uses the same `sqlite3*` handle as SQLite.
- **Same lifecycle**: Open → Use → Close.
- **Same thread safety**: One handle per thread.
- **Optional encryption**: Add `?encryption_key` parameter.

## Verdict

H-7 is confirmed. Turso fits Eta_pool with no structural changes, just an optional `?encryption_key` parameter.
