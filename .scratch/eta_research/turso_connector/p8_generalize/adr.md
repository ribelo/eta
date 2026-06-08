# ADR: Engine Generalization for Turso

**Status**: completed
**Hypothesis H-8**: Sql library can be generalized over Engine signature covering both SQLite and Turso.
**Verdict**: ✅ **CONFIRMED** — Turso uses identical C API to SQLite.

## Key Finding

Turso implements the **exact same C API** as SQLite. The `libturso_sqlite3` library is a drop-in replacement for `libsqlite3`.

### Evidence

1. **Same header**: `sqlite3.h` with identical function signatures
2. **Same semantics**: `sqlite3_open`, `sqlite3_step`, `sqlite3_finalize` work identically
3. **Same thread safety**: One `sqlite3*` per thread
4. **Same value types**: INTEGER, REAL, TEXT, BLOB, NULL

## Implications for Engine Generalization

### Option A: Reuse SQLite Engine (Recommended)

Since Turso uses the same C API as SQLite, the existing `Sqlite_engine` can be reused:

```ocaml
(* Turso is just SQLite with a different library *)
module Turso_engine = Sqlite_engine
(* Or: link against libturso_sqlite3 instead of libsqlite3 *)
```

**Pros**:
- No new code needed
- Same connector, same pool, same builder
- Drop-in replacement

**Cons**:
- Can't use Turso-specific features (BEGIN CONCURRENT, VECTOR) without extensions

### Option B: Separate Turso Engine

Create a separate `Turso_engine` that extends `Sqlite_engine`:

```ocaml
module Turso_engine = struct
  include Sqlite_engine
  
  (* Turso-specific extensions *)
  let enable_mvcc db = exec_pragma db "journal_mode" "'mvcc'"
  let begin_concurrent db = exec db "BEGIN CONCURRENT"
  let vector_distance_cos v1 v2 = ...
end
```

**Pros**:
- Can expose Turso-specific features
- Clean separation of concerns

**Cons**:
- More code to maintain
- Duplication of SQLite logic

## Recommendation

**Option A (Reuse SQLite Engine)** for the base connector, with **Turso-specific extensions** added as optional functions:

1. **Base connector**: Reuse `Sqlite_engine` by linking against `libturso_sqlite3`
2. **MVCC extension**: Add `enable_mvcc` function
3. **BEGIN CONCURRENT**: Add `begin_concurrent` function
4. **Vector search**: Add `vector_distance_cos` function

This gives us:
- Drop-in compatibility with existing SQLite code
- Access to Turso-specific features when needed
- Minimal code duplication

## Verdict

H-8 is confirmed. Turso can reuse the SQLite engine with optional extensions.
