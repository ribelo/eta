# Bug hunt findings

Runnable failing tests live in `bugs.ml` / `run.ml`. Run with:

```
nix develop -c dune exec test/bug_hunt/run.exe
```

All tests currently FAIL on purpose — each one asserts the behavior a correct
implementation must satisfy. None is "failing on principle"; each encodes a
real contract.

## Bug 1 — `Duration.scale` is not the identity at the maximum
`lib/eta/duration.ml`

`Duration.scale (Duration.ms max_int) 1.0` returns `0`, not `max_int`. The
overflow guard `scaled > float_of_int max_int` never fires at the boundary
because `float_of_int max_int` rounds the 63-bit max up to `2^62`; the product
equals `2^62` exactly, then `int_of_float 2^62` overflows to a negative int and
`clamp_nonnegative` collapses it to `0`. Scaling by `1.0` must be the identity.
This root cause also feeds `Schedule.scale_capped` and the linear/jitter paths.

## Bug 2 — jittered exponential backoff raises once delays saturate
`lib/eta/schedule.ml`

Exponential delays are deliberately clamped to the maximum representable
duration via `scale_capped`. But `Schedule.jittered` multiplies the inner delay
with raw `Duration.scale` (not the capped variant). Once the exponential delay
saturates at `ms max_int` and the jitter factor is `> 1.0`, `Duration.scale`
raises `Invalid_argument "Duration.scale"`. Advancing a legal jittered
exponential backoff — the most common retry policy — therefore crashes.

## Bug 3 — float column `DEFAULT` loses precision in generated schema SQL
`lib/sql/dsl.ml` (also `lib/turso/dsl_backend.ml`, `lib/duckdb/dsl_backend.ml`)

`value_to_sql_literal` renders floats with `string_of_float` (~12 significant
digits), which cannot round-trip a full-precision double. A declared
`~default:3.141592653589793` becomes `DEFAULT 3.14159265359`, so any row that
relies on the default stores a value different from the one declared. Present in
all three SQL backends.

## Bug 4 — SQLite decodes SQL NULL as a fabricated `0`/`""` through a non-nullable column
`lib/sql/types.ml` + `lib/sql/sqlite_stubs.c`

The typed DSL provides `nullable` and `column_is_null` precisely so NULL is
explicit in the types. The DuckDB and Turso backends raise a decode failure when
a NULL reaches a non-nullable decoder. The SQLite backend binds `int`'s decoder
directly to `Sqlite.column_int` (`sqlite3_column_int64`, no NULL check) and
`text`'s decoder to `column_text` (the C stub returns `""` for `SQLITE_NULL`), so
a NULL is silently decoded as `0`/`""`. The same typed program behaves
differently across Eta SQL backends and silently corrupts data.

## Bug 5 — DuckDB cannot read a TIMESTAMP/DATE/DECIMAL/UUID/ENUM column once any column is a LIST
`lib/duckdb/duckdb_stubs.c`

DuckDB results are materialized column-by-column. The non-LIST path
(`value_from_result`) decodes DATE/TIME/TIMESTAMP/DECIMAL/UUID/ENUM via its
default branch. But as soon as ANY result column is a `LIST`, the whole result
goes through the chunk path (`value_from_vector`), which only handles
BOOLEAN/INT*/FLOAT/DOUBLE/VARCHAR/BLOB/LIST and calls
`caml_failwith("duckdb unsupported vector result type")` for TIMESTAMP & friends.
So `SELECT [1,2,3] AS lst, TIMESTAMP '...' AS ts` fails even though the same
TIMESTAMP column reads fine on its own. Reproduced as a runnable test (the nix
dev shell ships `libduckdb`, and `ETA_DUCKDB_LIBRARY` is set), failing with
`query: duckdb unsupported vector result type`.

## Bug 6 — Turso `exec_script` silently runs only the first statement of a script
`lib/turso/connection.ml`

`exec_script` is `execute db sql []`, which prepares the SQL with
`sqlite3_prepare_v2` (NULL tail) and steps once. `prepare_v2` compiles only the
first statement, so every statement after the first `;` is silently dropped and
`exec_script` still returns `Ok ()`. The SQLite backend's `exec_script` uses
`sqlite3_exec` and runs the whole script, so the same multi-statement script
behaves differently across backends — and the Turso path violates the repo's
"break loudly" rule by no-op'ing the rest. Reproduced as a runnable test (the
nix dev shell ships `libturso_sqlite3` via `ETA_TURSO_LIBRARY`): after
`exec_script "CREATE TABLE a (...); CREATE TABLE b (...);"`, table `b` does not
exist (`no such table: b`).

## Bug 7 — DuckDB `execute` always reports 0 changed rows
`lib/duckdb/duckdb_stubs.c` (`eta_duckdb_execute`)

The stub returns `(int)result.deprecated_rows_changed`. Modern DuckDB does not
populate that deprecated field for prepared-statement execution (the supported
accessor is `duckdb_rows_changed`), so `Connection.execute` /
`Pool.Typed.execute_compiled` report `0` for every INSERT/UPDATE/DELETE even
when rows were changed. Reproduced as a runnable test: inserting three rows
reports `0` instead of `3`.

## Bug 8 — DuckDB decodes UUID / TIMESTAMPTZ / ENUM values as empty strings
`lib/duckdb/duckdb_stubs.c` (`value_from_result` default branch)

UUID/TIMESTAMPTZ/ENUM values are stringified with the deprecated
`duckdb_value_varchar`, which returns NULL for these types in modern DuckDB; the
stub maps a NULL varchar to `""`, so a non-NULL value silently decodes as the
empty string. DATE/TIME/TIMESTAMP/DECIMAL/INTERVAL still stringify correctly,
which is why the bug hides. Verified: `'…'::UUID` and a populated `ENUM` column
both decode to `""`.




