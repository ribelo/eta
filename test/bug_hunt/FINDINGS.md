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

## Bug 9 — LadybugDB decodes every Cypher LIST value as an empty string
`lib/ladybug/ladybug_stubs.c` (`arrow_value`)

Results come back over the Arrow C data interface. `arrow_value` handles the
scalar formats `b`/`l`/`g`/`u` and structs/nodes (`+s`) but has no case for the
Arrow list formats `+l`/`+L`; it falls through to a default that returns
`String ""`. So every Cypher LIST (e.g. `[1,2,3]`, `collect(x)`, a list nested
in a map) silently decodes as the empty string instead of `Value.List` — even
though `Value.t` has a `List` constructor and `query_string` renders the list
correctly. Verified: `RETURN [1,2,3] AS v` via `Decode.value` yields
`String ""`.


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

## Bug 10 — LadybugDB decodes every relationship as Node instead of Rel
`lib/ladybug/ladybug_stubs.c` (`arrow_value` → `arrow_node`)

Relationships are returned as Arrow structs with `_LABEL`, `_ID`, `_SRC`, and
`_DST` children. `arrow_value` uses `find_child(schema, "_LABEL") >= 0` to
decide "this is a node", but relationships ALSO have `_LABEL`. There is no
check for `_SRC`/`_DST` (which only rels have), so every relationship silently
decodes as `Value.Node` instead of `Value.Rel`.
Verified: `MATCH ()-[r:Knows]->() RETURN r` yields `Node(labels=[Knows])`.

## Bug 11 — LadybugDB decodes every path as Map instead of Path
`lib/ladybug/ladybug_stubs.c` (`arrow_value`)

Paths are returned as Arrow structs with `_NODES` and `_RELS` children. The
stub has no `arrow_path` function at all, so paths fall through to
`arrow_struct_map` and decode as `Value.Map` instead of `Value.Path`.
Verified: `MATCH p=(:Person)-[:Knows]->(:Person) RETURN p` yields
`Map{_NODES=List[...]; _RELS=List[...]}`.

## Bug 12 — LadybugDB decodes timestamps/dates/intervals as empty String ""
`lib/ladybug/ladybug_stubs.c` (`arrow_value`)

Arrow temporal types use format strings like `ttn` (timestamp[ns]), `tdD`
(date32), and interval formats. `arrow_value` handles `b`/`l`/`g`/`u`/`+l`/`+L`/`+s`
but has NO case for temporal types; they fall through to the default
`String ""`. So `timestamp('2020-01-01')`, `date('2020-01-01')`, and
`interval('1 day')` all silently decode as the empty string.
Verified: `RETURN timestamp('2020-01-01') AS v` yields `String ""`.

## Bug 13 — LadybugDB `Param.map` round-trips as empty String ""
`lib/ladybug/ladybug_stubs.c` (param binding / result decode)

A `Param.map` binds correctly (`query_string` shows the map reaches the
engine), but when the value is returned and decoded through the typed `query`
path it becomes `String ""`. `Param.struct_` and inline maps both round-trip
correctly as `Map`, so the bug is specific to the map-parameter path — likely
the parameter is rendered with `=` syntax instead of `:` and Ladybug returns a
different Arrow type the stub cannot decode.
Verified: `RETURN $x` with `Param.map "x" [("a", Int 1L)] yields `String ""`.

## Bug 14 — Migrate `-- no-transaction` prefix is too greedy
`lib/sql/migrate.ml` (`strip_no_transaction_directive`)

The directive stripper uses `starts_with sql "-- no-transaction"`, which
matches ANY string starting with that prefix — including
`"-- no-transactional"` (a different word). A migration file starting with
`-- no-transactional\n...` is therefore incorrectly flagged as `no_tx=true`
and its checksum is computed on the stripped SQL instead of the original.
Correct behavior: only the exact directive `-- no-transaction` followed by a
newline or end-of-string should trigger the no-transaction path.
Verified: a file `001_test.sql` containing `-- no-transactional\nSELECT 1;`
resolves with `no_tx=true`.

## Bug 15 — Migrate silently skips symlinked migration files
`lib/sql/migrate.ml` (`is_regular_file`)

The directory scanner uses `Unix.lstat` to test whether a path is a regular
file. `lstat` returns `S_LNK` for symlinks, even when they point to regular
files, so any symlinked migration is silently skipped. A common deployment
pattern is to symlink migrations into a staging directory; this bug breaks
that workflow without any error.
Verified: a directory containing only a symlink `001_test.sql -> real/001_test.sql`
resolves to 0 migrations.




