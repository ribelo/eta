
Here is the deep findings report for the `Eta` codebase, divided into the requested independent reviews.

### 1. Correctness Review

**[P0] Resource leak in `Effect.race` drops successful values of losing branches**
- **Files**: `lib/eta/effect_concurrent.ml` (`race_eval`), `lib/eta/pool.ml` (`acquire_permit`)
- **Detail**: When `Effect.race` collects results from its spawned fibers, it accepts the first `Exit.Ok value` and cancels the others via `switch_fail`. It then drains any remaining results in `drain_cancelled_losers`, deliberately dropping any `Exit.Ok _` values from branches that completed concurrently. If a losing branch successfully acquired a manual resource (e.g., a network connection, a file descriptor, or a `Semaphore` permit), that resource is permanently leaked because the success value never reaches a caller that can release it. 
- **User Impact**: Explicitly triggered by `Pool.acquire_permit`, which races `Semaphore.acquire` against `wait_for_shutdown`. If the pool begins shutting down at the exact moment a permit is acquired, the permit is silently dropped. 

**[P0] C resource leak in LadybugDB stubs on OCaml exceptions**
- **File**: `lib/ladybug/ladybug_stubs.c`
- **Detail**: In `execute_direct`, `execute_prepared_values`, and `materialize_arrow_rows`, the C code stack-allocates an `lbug_query_result` struct that owns foreign memory. It then calls `materialize_arrow_rows(&result)`. If `materialize_arrow_rows` invokes `caml_failwith` (e.g., via `fail_last` or on Arrow format validation) or the OCaml GC raises `Out_of_memory`, the C execution aborts via `longjmp`. The manual `api.query_result_destroy(&result)` cleanup is bypassed, leaking the query result memory. (The DuckDB bindings correctly avoid this using a `CAMLlocal` custom block finalizer).

**[P1] Unbounded memory growth in HTTP/2 `body_stream_async`**
- **File**: `lib/http/h2/multiplexer.ml` (lines 305-330)
- **Detail**: In `schedule_read`, there is a `while !keep_scheduling` loop that re-arms as long as `delivered_sync` is true. If `ocaml-h2` delivers data synchronously (e.g., from a large, already-received frame buffer), this loop will continuously pull chunks and push them into the unbounded `events` queue without yielding. This entirely circumvents application-level backpressure, risking massive memory spikes or Out-of-Memory crashes when reading large payloads.

**[P1] Silent side-effect dropping and error mutation in `Effect.catch`**
- **File**: `lib/eta/effect_core.ml` (`catch_causes`, lines 145-165)
- **Detail**: When `catch` processes a `Concurrent` cause tree, it maps the handler over all child causes. If *some* but not *all* branches are handled successfully, it returns `Uncaught` with the unhandled causes and drops the successfully recovered values. However, the side effects of the successfully handled branches have already executed! The caller receives an overall failure and assumes the entire operation aborted, hiding successful side effects (like network requests or database commits) and dropping the handled errors from the trace.

**[P2] Trace Context parser violates W3C forward-compatibility**
- **File**: `lib/eta/trace_context.ml` (lines 53-60)
- **Detail**: `extract` strictly matches the `traceparent` version to `"00"`. The W3C specification mandates forward compatibility: versions strictly greater than `00` must still be parsed by attempting to match the `00` format and ignoring trailing fields. By falling into `| _ -> None`, Eta drops valid trace contexts from newer upstream services.

**[P2] Turso/SQLite `column_text` silently returns empty strings on OOM**
- **Files**: `lib/turso/turso_stubs.c` (line 330), `lib/sql/sqlite_stubs.c` (line 529)
- **Detail**: If SQLite encounters an Out-Of-Memory error while converting a value to text (e.g., integer to string), `sqlite3_column_text` returns `NULL` and `sqlite3_column_bytes` returns `0`. The Eta stubs translate `len == 0 && text == NULL` to an empty string `""` instead of raising an error. Because `read_value` filters out actual SQL `NULL`s before calling this, returning `""` silently corrupts data on memory exhaustion.

### 2. Code Quality Review

**[P2] Massive duplication across C stubs**
- **Files**: `lib/sql/sqlite_stubs.c` and `lib/turso/turso_stubs.c`
- **Detail**: Turso (`libturso_sqlite3`) is a direct fork of SQLite. As a result, nearly 1,000 lines of C API bindings (dynamic loader boilerplate, `bind_int`, `column_text`, etc.) and the matching OCaml driver logic are 100% duplicated. These should be unified into a single generic C extension and OCaml module parameterized by the target library name.

**[P2] Duplicated primitive type definitions across SQL DSL backends**
- **Files**: `lib/sql/dsl.ml`, `lib/duckdb/dsl_backend.ml`, `lib/turso/dsl_backend.ml`
- **Detail**: The `Backend` modules defining identical `int`, `int64`, `bool`, `float`, `text`, and `nullable` codecs are copied across all three database connectors. These primitives should be hoisted into `Eta_sql_dsl` to provide a standard set of types that backends simply include.

**[P3] Inefficient manual frame parsing logic duplicated across modules**
- **Files**: `lib/http/h2/informational_filter.ml` and `lib/http/h2/security.ml`
- **Detail**: Both modules manually parse HTTP/2 frame envelopes (`frame_length`, `frame_type`, `stream_id` via bitwise shifts). This logic should be centralized in `lib/http/h2/frame.ml`, which currently only contains encoding logic.

**[P2] Hand-rolled SHA-1 Implementation**
- **File**: `lib/http/ws/codec.ml` (lines 115-185)
- **Detail**: The AI implemented a 70-line pure OCaml SHA-1 hashing algorithm (using `Int32` bitwise operators and MD padding) just to compute the `Sec-WebSocket-Accept` header. While functionally correct, writing bespoke cryptography primitives to avoid a `digestif` dependency is a classic AI behavior and a significant maintenance hazard.

**[P2] Hallucinated DuckDB Transaction Modes**
- **File**: `lib/duckdb/connection.ml` (lines 79-84)
- **Detail**: The AI copy-pasted SQLite transaction logic into the DuckDB driver, including support for `BEGIN IMMEDIATE TRANSACTION`. DuckDB does not support `IMMEDIATE` or `DEFERRED` transaction modes; attempting to execute `BEGIN IMMEDIATE` will throw a syntax error at runtime.

**[P3] Defensive standard library reimplementations**
- **File**: `lib/eta/cause.ml` (lines 10-14)
- **Detail**: The code hand-rolls `equal_option` and `equal_list` implementations instead of using standard library functions (`Option.equal` and `List.equal`). This is defensive AI boilerplate generated to avoid hypothetical OCaml version mismatches.
