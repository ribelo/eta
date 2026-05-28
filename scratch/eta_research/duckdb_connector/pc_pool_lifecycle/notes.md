# P-C — Pool Lifecycle with Database Parent Handle

**Status**: completed (real test with actual Eta.Pool)
**Run log**: `scratch/eta_research/duckdb_connector/pc_pool_lifecycle/pool.log`

## Test Design

Used actual `Eta.Pool` (not a toy) with:
- `Pool.create` with DuckDB acquire/release functions
- `Pool.with_resource` for connection use
- `Pool.shutdown` for cleanup
- Eio runtime via `Eio_main.run`

## Results

### Test 1: Safe ordering (pool shutdown → db close)
```
Connection use: ok=true
Pool shutdown: OK
Database closed after pool: OK
Safe ordering: PASSED
```

### Test 2: Unsafe ordering (db close while pool alive)
```
Connection use before close: ok=true
Database closed (pool still alive)
Connection use after db close: ok=true (UNEXPECTED)
Unsafe ordering: connection still works?
Pool shutdown after db close: OK
Unsafe ordering: completed
```

## Key Finding

**Unsafe ordering does NOT crash for in-memory DuckDB.** Connections continue to work after `duckdb_close` is called. This is because DuckDB keeps the in-memory database alive as long as there are active connections.

This contradicts my earlier claim that "closing Database before Pool causes segfaults." That claim was based on an assumption, not on evidence.

## Implications

For DuckDB (in-memory), the lifecycle constraint is weaker than assumed:
- Database can be closed while connections are active
- Connections continue to work until explicitly disconnected
- Pool shutdown still works after db close

For file-backed DuckDB or SQLite, this may differ.

## Verdict

**PARTIAL** — Safe ordering works. Unsafe ordering does not crash for in-memory DuckDB, but behavior may differ for file-backed databases.

## Artifacts

- Run log: `scratch/eta_research/duckdb_connector/pc_pool_lifecycle/pool.log`
- Source: `scratch/eta_research/duckdb_connector/pc_pool_lifecycle/pc_pool_probe.ml`
- Command: `nix develop .#oxcaml --command dune exec scratch/eta_research/duckdb_connector/pc_pool_lifecycle/pc_pool_probe.exe`
