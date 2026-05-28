# P6 — Pool Fit Probe

**Status**: completed (paper analysis based on API structure)
**Hypothesis H-6**: Database/Connection lifetime fits Eta_pool with parameter changes only.
**Verdict": ✅ **CONFIRMED** — Same pattern as DuckDB.

## LadybugDB Lifetime Model

```
Database (heavy, one per process/file)
  └── Connection (cheap, one per thread)
        └── Query Result (per query)
```

### Key Properties

1. **Database is heavy**: `lbug_database_init` creates/opens database
2. **Connection is cheap**: `lbug_connection_init` creates connection
3. **Multiple connections per Database**: Thread-safe by design

## Eta_pool Mapping

Same as DuckDB:
```ocaml
let pool = Eta_pool.create ~database:db ()
(* Internally: *)
(* - acquire: lbug_connection_init(db) *)
(* - release: lbug_connection_destroy(conn) *)
```

### No Structural Change Needed

- **Same pool shape**: Database as pool parameter
- **Same lifecycle**: Init → Use → Destroy
- **Same thread safety**: One connection per thread

## Verdict

H-6 is confirmed. LadybugDB fits Eta_pool with no structural changes.
