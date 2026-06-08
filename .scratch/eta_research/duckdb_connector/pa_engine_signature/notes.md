# P-A — ENGINE Signature Build Test

**Status**: completed (real build, captured log)
**Build log**: `scratch/eta_research/duckdb_connector/pa_engine_signature/build.log`

## Build Result

```bash
nix develop .#oxcaml --command dune build --verbose \
  scratch/eta_research/duckdb_connector/pa_engine_signature
```

**Exit code: 0** — compiles without warnings or errors.

The build log shows:
- `ocamldep.opt -modules -impl sqlite_engine.ml` — dependency analysis
- `ocamlc.opt ... -c -impl sqlite_engine.ml` — bytecode compilation
- `ocamlopt.opt ... -c -impl sqlite_engine.ml` — native compilation
- `ocamlopt.opt ... -a -o pa_engine_signature.cmxa` — library archive

No warnings, no errors, no type mismatches.

## Real Issues Found

### Issue 1: Collapsed types
```ocaml
type database = Sqlite.db
type connection = Sqlite.db  (* Same type! *)
```

SQLite conflates database and connection into one handle. DuckDB has separate `duckdb_database` and `duckdb_connection` types. The ENGINE signature requires both, but SQLite cannot satisfy them as distinct types without wrapping.

**Impact**: MEDIUM — requires a wrapper type for SQLite to distinguish database from connection.

### Issue 2: Discarded return code
```ocaml
let close_database db =
  let _rc = Sqlite.close db in
  Ok ()
```

`Sqlite.close` returns `rc` (result code). The implementation silently discards it, always returning `Ok ()` even on error.

**Impact**: LOW — fixable by checking rc and returning Error on non-OK.

### Issue 3: No-op connect/disconnect
```ocaml
let connect db = Ok db  (* SQLite: database IS connection *)
let disconnect _conn = Ok ()  (* No-op *)
```

For SQLite, connect is identity and disconnect is a no-op. This works for SQLite but doesn't model the DuckDB lifecycle where connect/disconnect are real operations.

**Impact**: MEDIUM — the abstraction is leaky. SQLite doesn't need connect/disconnect, but DuckDB does.

## Verdict

**PARTIAL** — The ENGINE signature compiles, but the implementation has real issues:
1. SQLite cannot distinguish database from connection without wrapping
2. Return codes are silently discarded
3. Connect/disconnect are no-ops for SQLite

These are not blockers, but they require wrapper types and proper error handling.

## Artifact

- Build log: `scratch/eta_research/duckdb_connector/pa_engine_signature/build.log` (24 lines, shows all compilation steps)
- Source: `scratch/eta_research/duckdb_connector/pa_engine_signature/sqlite_engine.ml`
- Command: `nix develop .#oxcaml --command dune build --verbose scratch/eta_research/duckdb_connector/pa_engine_signature`
