## 1. Correctness Review

### P1 — `Eta.Resource` has unsynchronized cache updates and can publish stale refresh results

`Resource.t` stores `mutable value` and a mutable failure list with no mutex, version token, single-flight guard, or “newer refresh wins” rule. Both `get` and `refresh` run `resource.load` and then assign `resource.value <- Some value`; `auto` also starts a daemon refresh loop. If a manual `refresh`, a `get` after a cache miss, and the daemon overlap, a slower old load can overwrite a newer value. The failure list is similarly a plain ref mutated from the daemon path and read through `failures`. This is observable for resources that load credentials, routing tables, or configuration.  

### P1 — SQL `in_select` can produce invalid SQL despite the typed DSL

The DSL tracks the decoded OCaml type of a compiled select, but projection width is independent from the decoded type: `Projection.map` preserves the SQL projection while changing the OCaml decoded type. A user can build a projection with two SQL columns and map it to the first value, producing an `int Compiled.select` whose SQL is still `SELECT col1, col2 ...`. `Expr.in_select` then accepts that `int Compiled.select` for an `int column` and blindly emits `column IN (<query.sql>)`, which is invalid SQL because `IN` subqueries must return one column. The implementation stores projection `width` and SQL columns, exposes `Projection.map`, renders every projection column into the final `SELECT`, and `in_select` does not check width.    

### P1 — Turso close can mark the OCaml handle closed while the native DB remains open

`lib/turso/connection.ml` sets `db.closed <- true` before checking whether `raw_close db.raw` succeeds. The C stub only nulls `db->db` when `close_v2` returns `SQLITE_OK`; on failure, the native pointer remains live. The OCaml wrapper then reports an error but leaves the wrapper permanently closed, making it impossible to retry through that handle and risking leaked native resources.  

### P2 — DuckDB pool shutdown hides database close failures

`Eta_duckdb.Pool.shutdown` runs `Database.close t.database` inside a blocking effect but discards the result with `ignore`. That means a failed DuckDB database close is reported as a successful pool shutdown. Since the public `Database.close` returns an error type, suppressing it at the pool boundary loses the only signal that native resources or child connection cleanup failed. 

### P2 — DuckDB `connect` runs native work without a blocking section

Most DuckDB operations that may block release the OCaml runtime lock, including disconnect. `eta_duckdb_connect`, however, calls `api.connect` directly without `caml_enter_blocking_section` / `caml_leave_blocking_section`. Opening a connection can touch the database catalog/filesystem and may stall the runtime domain. This is inconsistent with the surrounding FFI policy.  

### P2 — DuckDB dynamic loader leaks a `dlopen` handle when symbol resolution fails

`load_api_unlocked` sets `api.handle` after a successful `dlopen`, then resolves a long list of symbols. If any symbol is missing, it returns `0` without `dlclose(api.handle)` or resetting the partial state. Since `api.attempted` is set before loading, future attempts also stop immediately. This is a process-lifetime leak and a poor recovery story for mismatched DuckDB shared libraries.  

### P2 — Turso `prepare` lacks SQLite’s `stmt == NULL` success-path guard

The SQLite stub treats `rc != SQLITE_OK || stmt == NULL` as failure. The Turso stub checks only `rc != SQLITE_OK` and then stores `stmt`, even though a SQLite-compatible `prepare_v2` can produce no statement for empty/comment-only SQL. That can create a statement wrapper with a null native statement and push failures into later operations.  

### P2 — Multipart boundary generation can be collided by request fields

OpenAI transcription multipart bodies use a boundary derived from `Digest.bytes file.data`, then write user-controlled fields and the file without checking whether the boundary string appears in any part. Multipart encoders normally choose a random boundary and/or verify non-occurrence. A caller controlling prompt or extra fields can embed `--eta-ai-<digest>` and corrupt the request framing. 

### P2 — `Random.int_in_range` overflows on wide integer ranges

`int_in_range` computes `span = max - min + 1` in OCaml `int`. For wide ranges, such as near `min_int` to `max_int`, this can overflow before conversion to float. The public documentation promises an inclusive range helper, but the implementation is only safe for ranges whose span fits in `int`.  

### P3 — `Semaphore.waiting` can overcount blocked fibers

`waiting` returns `Queue.length t.waiters`, but the queue can contain `Resolved_unclaimed` and `Claimed` waiters as well as still-blocked waiters; compaction preserves non-cancelled non-waiting states. The interface documents this as “Number of fibers currently blocked waiting for permits,” so stats/metrics can be inflated.   

### Boundary note — the typed SQL DSL is explicitly not a closed safety boundary

This is not itself a bug, but it matters for the “can it be bypassed?” question. The SQL package exposes `Pool.Raw` and lower-level connection APIs that explicitly bypass typed query construction and make callers own SQL validity, parameter ordering, and decoding. The DSL also documents that its scope evidence does not prove all SQL validity rules.   

I did not find a P0 issue in the core effect `race`/finalizer path from static inspection. The implementation explicitly cancels losers after a winner, protects the post-winner cleanup window, and surfaces loser finalizer diagnostics rather than silently returning success. 

## 2. Code Quality Review

### P2 — Several public-facing modules are too large to audit locally

The largest files combine multiple responsibilities: C dynamic loading, ownership, parameter binding, row materialization, and error conversion in the FFI stubs; SQL AST construction, rendering, and decoding in the DSL; and stream AST/interpreter/fusion/concurrency in `eta_stream.ml`. Examples include `ladybug_stubs.c` at 1246 LOC, `sqlite_stubs.c` at 1098 LOC, `duckdb_stubs.c` at 999 LOC, `eta_sql_dsl_query.ml` at 935 LOC, `eta_stream.ml` at 818 LOC, `eta_ladybug.ml` at 784 LOC, and `eta_otel.ml` at 760 LOC. The pool module even opens with a comment explaining why state-machine, semaphore, and metrics live together, which is a valid invariant concern but also a sign that the module has accumulated too much authority.  

### P2 — `Effect.Private` leaks unstable extension hooks into the public surface

The public `Effect.mli` exposes `Private.daemon`, `Private.named_attrs`, and metric batching hooks. The docs warn external applications away from them, but the symbols are still public API. This makes it easy for sibling packages and users to rely on unstable runtime behavior and hardens internal design decisions prematurely. 

### P2 — SQL compiled/query representation leaks through accessors and raw APIs

The core DSL `Compiled` interface exposes SQL strings, parameter lists, and row decoders. That is useful for drivers, but it means the abstraction boundary is “query builder plus generated SQL,” not a sealed relational algebra. Combined with `Pool.Raw`, users have several sanctioned escape hatches. This should be documented as an intentional design, not marketed as type-safe SQL in the strong sense.  

### P2 — SQLite/Turso duplication is intentional but still high-risk

The comments explain why system SQLite and Turso keep separate FFI contracts, which is reasonable. But both stubs must independently maintain close/finalize behavior, prepare behavior, binding rules, column decoding, interruption, and error mapping. The Turso `prepare` discrepancy above is exactly the kind of drift this duplication invites.  

### P2 — Vestigial `pool_lease` state in SQLite connections

`lib/sql/connection.ml` carries a mutable `pool_lease` field and exposes `pool_lease` / `set_pool_lease`, but the surrounding package evidence does not show it participating in pool safety. If it is a planned generation counter or ownership token, it is currently not enforcing anything; if not, it is dead state that makes connection lifecycle reasoning harder.  

### P3 — Builder APIs repeatedly append to the end of lists

Several builder paths use `@ [x]` to preserve construction order. This is readable but O(n) per append and becomes O(n²) for larger rows/queries. Examples include DuckDB bulk rows and SQL insert values. For small schema/query builders this may be acceptable, but it is a recurring non-idiom in OCaml code where reverse accumulation is usually cheaper and clearer once factored.  

### P3 — Some public documentation is stale or contradicts the implementation

`eta_http.mli` says the h1 parser/writer, transport, pool integration, and live request path “land later,” while `eta_http.ml` already exports `request`, retry, TLS, transport, H1, H2, and WebSocket modules. This is not a runtime bug, but stale public package docs harm maintainability and user trust.  

## 3. AI Slop Review

These are not proof of AI generation; they are cleanup signals that commonly appear in generated or over-assisted code.

### P2 — Implementation comments read like retained design justifications rather than maintained code comments

The pool module starts with an architectural defense of why lifecycle state, semaphores, and metrics are in one module; the SQL DSL functor similarly explains why splitting expression construction/rendering/decoding would expose an AST. Those comments may be true, but they are doing the work of an ADR inside implementation files. They also make the code feel “argued into shape” rather than simplified into smaller, testable units.  

### P2 — Stale roadmap prose looks like unreviewed scaffolding

The `eta_http.mli` “S1 foundations” paragraph appears to describe an earlier milestone, not the current implementation. This is a classic slop marker: a generated or copied package overview survives after the code evolves.  

### P3 — Single-element `all_settled` plus impossible `assert false`

`Resource.auto` wraps a single `refresh resource` in `Effect.all_settled [ ... ]`, then pattern matches `[ Ok () ]`, `[ Error cause ]`, and `_ -> assert false`. This is defensive boilerplate around an impossible list shape that a direct error-handling combinator would express more clearly. It is minor, but it is the kind of plausible-looking abstraction that adds noise without value. 

### P3 — Repeated provider endpoint wrappers are mostly mechanical

OpenAI `Responses` and OpenRouter `Responses_impl` follow the same `request` / `run` / `stream` template: choose provider, encode, build request, run span-aware transport. Some duplication is expected across provider packages, but the repeated scaffolding reads generated and increases the chance of subtle behavioral drift.  

### P3 — O(n²) list appends in builders look like “obvious” generated code

The `row @ [ ... ]`, `query.values @ [ ... ]`, and `params := !params @ ...` patterns are small but repeated. They preserve order with minimal thought, but in OCaml they are usually a smell in builders and loops.   

### P3 — Formatting artifact in queue receive path

`lib/eta/queue.ml` has visibly mis-indented tabbed lines inside `recv_sync`. This is minor, but in concurrency primitives it increases review friction because readers must distinguish formatting noise from lock/cancellation structure. 
