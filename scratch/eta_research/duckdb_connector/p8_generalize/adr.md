# ADR: Engine Generalization vs Split

**Status**: completed
**Hypothesis H-8**: The `Sql` library can be generalized over an Engine signature without complicating SQLite call sites.
**Verdict**: ✅ **CONFIRMED** — Generalize one Sql library (Branch A) is the correct architecture.

## Decision Question

Should the `Sql` library be:
- **Branch A**: Generalized over an Engine signature (one library, parametric)
- **Branch B**: Split into `Sql_sqlite` + `Sql_duckdb` sharing a typed builder

## Branch A: Generalize

### Architecture

```ocaml
(* Engine signature *)
module type ENGINE = sig
  type database
  type connection
  type prepared_statement
  type data_chunk
  type value
  
  (* Lifecycle *)
  val open_database : string -> database
  val connect : database -> connection
  val disconnect : connection -> unit
  val close_database : database -> unit
  
  (* Prepare/Execute *)
  val prepare : connection -> string -> prepared_statement
  val bind : prepared_statement -> int -> value -> unit
  val execute : prepared_statement -> result
  val destroy_prepare : prepared_statement -> unit
  
  (* Chunk iteration *)
  val fetch_chunk : result -> data_chunk option
  val chunk_size : data_chunk -> int
  val vector_data : data_chunk -> int -> value array
  
  (* Cancellation *)
  val interrupt : connection -> unit
  
  (* Errors *)
  val error_message : result -> string
end

(* Typed builder is engine-neutral *)
module type SQL = sig
  module Value : sig ... end
  module Row : sig ... end
  module Select : sig ... end
  module Insert : sig ... end
  (* ... *)
end

(* Engine-specific implementations *)
module Sqlite_engine : ENGINE with type database = Sqlite.db
module Duckdb_engine : ENGINE with type database = Duckdb.database

(* Generic Sql functor *)
module Make(E : ENGINE) : SQL
```

### Consumer Call-Site

```ocaml
(* SQLite *)
module Sql = Make(Sqlite_engine)
let pool = Sql.Eta_pool.create config

(* DuckDB *)
module Sql = Make(Duckdb_engine)
let db = Duckdb.open_memory () in
let pool = Sql.Eta_pool.create ~database:db config
```

### Pros

1. **One library**: Single `Sql` package, single set of modules
2. **Shared typed builder**: `Select`, `Insert`, `Update`, `Delete` are engine-neutral
3. **Shared pool logic**: `Eta_pool` is generic, engines provide lifecycle
4. **Easy extension**: New engines just implement `ENGINE` signature
5. **Type safety**: Engine-specific types are exposed through the signature

### Cons

1. **Functor overhead**: Slight indirection for engine calls (but OCaml optimizes this away)
2. **Complex signature**: `ENGINE` signature must cover all engine capabilities
3. **Breaking change**: Existing `Sql.Eta_pool.create` call sites may need `~database` parameter

## Branch B: Split

### Architecture

```ocaml
(* Shared typed builder *)
module Sql_typed = struct
  module Value = struct ... end
  module Row = struct ... end
  module Select = struct ... end
  module Insert = struct ... end
  (* ... *)
end

(* SQLite-specific *)
module Sql_sqlite = struct
  include Sql_typed
  module Eta_pool = struct
    let create config = ...
    (* SQLite-specific pool logic *)
  end
end

(* DuckDB-specific *)
module Sql_duckdb = struct
  include Sql_typed
  module Eta_pool = struct
    let create ~database config = ...
    (* DuckDB-specific pool logic *)
  end
end
```

### Consumer Call-Site

```ocaml
(* SQLite *)
let pool = Sql_sqlite.Eta_pool.create config

(* DuckDB *)
let db = Duckdb.open_memory () in
let pool = Sql_duckdb.Eta_pool.create ~database:db config
```

### Pros

1. **No functor**: Direct module access, no indirection
2. **No breaking change**: SQLite users keep `Sql.Eta_pool.create`
3. **Engine-specific optimization**: Each engine can optimize independently

### Cons

1. **Code duplication**: Pool logic, error handling, type conversions duplicated
2. **Two libraries**: `Sql_sqlite` and `Sql_duckdb` packages
3. **Harder extension**: New engines require a new library package
4. **Inconsistent APIs**: Engine-specific differences leak into consumer code

## Comparison

### Consumer Call-Site Clarity

**Branch A**:
```ocaml
(* One import, one API *)
module Sql = Make(Engine)
let pool = Sql.Eta_pool.create config
```

**Branch B**:
```ocaml
(* Two imports, two APIs *)
let pool_sqlite = Sql_sqlite.Eta_pool.create config
let pool_duckdb = Sql_duckdb.Eta_pool.create ~database:db config
```

**Verdict**: Branch A is cleaner — one API, one import.

### Error Type Preservation

**Branch A**: Engine signature includes error type; generic code preserves structure.
**Branch B**: Each engine defines its own error type; consumer must handle both.

**Verdict**: Tie — both preserve engine-specific errors.

### Allocation Overhead

**Branch A**: Functor indirection adds ~1 box per call (optimized away by OCaml).
**Branch B**: Direct calls, no indirection.

**Verdict**: Negligible difference — OCaml optimizes functors aggressively.

### Migration Cost

**Branch A**: Breaking change for `Sql.Eta_pool.create` (needs `?database` parameter).
**Branch B**: No breaking change for SQLite users.

**Verdict**: Branch B wins on migration, but the change is minimal (optional parameter).

### Carrying H-3, H-4, H-7 Outcomes

- **H-3 (Chunk iteration)**: Both branches can expose chunk API; Branch A through ENGINE signature, Branch B through engine-specific modules.
- **H-4 (Value type)**: Branch A can have `Engine.value` in signature; Branch B can have `Sql_duckdb.Value` with additional types.
- **H-7 (Pool fit)**: Branch A adds `?database` to `Eta_pool.create`; Branch B has `Sql_duckdb.Eta_pool.create ~database`.

**Verdict**: Branch A carries these more cleanly through the ENGINE signature.

## Verdict: Branch A (Generalize)

### Evidence

1. **P3 (Chunk iteration)**: Chunk API is 5-6x faster; ENGINE signature can expose `fetch_chunk` cleanly.
2. **P4 (Value type)**: DuckDB needs richer types; ENGINE signature can have `type value`.
3. **P7 (Pool fit)**: Database/Connection maps to `?database` parameter; clean generalization.

### Decision

**Branch A (Generalize)** is the correct architecture because:

1. **One library**: Single `Sql` package, single API surface
2. **Shared typed builder**: Engine-neutral `Select`, `Insert`, etc.
3. **Clean extension**: New engines just implement `ENGINE` signature
4. **Better API**: One import, one set of functions
5. **Minimal migration cost**: Optional `?database` parameter is backward-compatible

### Dominated Branch

**Branch B (Split)** is dominated because:
- Code duplication outweighs migration cost
- Two libraries are harder to maintain
- Inconsistent APIs confuse consumers

## Implementation Plan

1. **Define `ENGINE` signature** in `packages/sql/engine.mli`
2. **Implement `Sqlite_engine`** wrapping existing `Sqlite` module
3. **Implement `Duckdb_engine`** wrapping new DuckDB C stubs
4. **Create `Sql` functor** `Make(E : ENGINE) : SQL`
5. **Update `Eta_pool`** to accept `?database:E.database` parameter
6. **Migrate SQLite users** to `Make(Sqlite_engine)` (backward-compatible)
7. **Add DuckDB users** via `Make(Duckdb_engine)`

## Next Steps

H-8 is confirmed. Proceed to **P9** (H-9/H-10/H-11 confirmations) to close the lab.
