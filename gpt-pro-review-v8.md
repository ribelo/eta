## 1. Correctness Review

### P0 — DuckDB pool shutdown can close the database while active leases still exist

**Files:** `lib/duckdb/pool.ml:69-89`, `lib/duckdb/pool.ml:126-133`, `lib/eta/pool.ml:531-574`

`Eta.Pool.shutdown ?deadline` starts shutdown, closes idle entries, then waits until `active = 0`; when a deadline is supplied it can fail with `Pool_shutdown_timeout` before all active resources drain. `Eta_duckdb.Pool.shutdown` wraps that in `Effect.finally close_database`, so the database is closed even when the pool timed out waiting for active connections. The DuckDB pool owns one database and leases connections from it, so this can invalidate handles still being used by active blocking work. `Eta.Pool.shutdown` explicitly uses a timeout around `wait_until_drained`, while DuckDB’s shutdown always runs `duckdb.close_database` in `finally`.  

This is a correctness bug, not just a lifecycle policy issue. A deadline timeout should not mean “close the parent database anyway” unless all leased children are proven quiescent.

### P0 — DuckDB public connection/database handles are not synchronized against close/query races

**Files:** `lib/duckdb/types.ml:40-79`, `lib/duckdb/connection.ml:7-28`, `lib/duckdb/connection.ml:58-66`, `lib/duckdb/database.ml:15-34`, `lib/duckdb/database.ml:72-82`

DuckDB handles are mutable records with `closed` flags and a mutable `connections` list, but no mutex protects those fields. Public `Connection.query`, `execute`, and `exec_script` check `closed` and immediately call raw C functions; `Connection.close` and `Database.close` can concurrently disconnect or close the underlying handles. The package also tracks child connections in `database.connections` and closes them from `Database.close`, again without synchronization.   

The pool reduces this risk for normal pooled operations, but the raw public `Database` / `Connection` API still permits concurrent close/query/interrupt patterns that can destroy a native handle while another fiber or systhread is using it.

### P1 — `Effect.finally` drops cleanup failures when the primary path is cancellation

**Files:** `lib/eta/effect_resource.ml:17-42`, `lib/eta/runtime_core.ml:215-257`

`Effect.finally` preserves cleanup failures on success and typed/unchecked failure, but in the `Eio.Cancel.Cancelled` branch it runs cleanup and then raises the cancellation exception regardless of whether cleanup failed. By contrast, the lower-level runtime finalizer path explicitly converts cancellation plus finalizer failure into `Cause.suppressed ~primary:Cause.interrupt ~finalizer`.  

That makes `finally` observably less safe than scoped `acquire_release`: important cleanup failures can vanish precisely during cancellation, when cleanup diagnostics matter most.

### P1 — `race` can lose losing-child cleanup/finalizer failures after a winner is selected

**Files:** `lib/eta/effect_concurrent.ml:68-98`, `lib/eta/effect_concurrent.ml:37-58`

`race_eval` records failures only while collecting until a winner appears. Once a child returns `Exit.Ok`, it sets `winner`, fails the switch with `Race_won`, awaits cancellation, and later returns `ok value`. There is no pass that collects failure causes produced by cancelled losers’ finalizers after the winning child has been chosen. The related `par_run_forks` path records causes from fork bodies before failing the switch, but `race`’s success path does not aggregate post-winner cleanup failures. 

For `race`, ignoring ordinary losing typed failures is expected; ignoring losing **finalizer/cleanup defects** is much more dangerous because it can hide resource-release failures.

### P1 — Ladybug Arrow materialization leaks native Arrow resources on OCaml exceptions

**Files:** `lib/ladybug/ladybug_stubs.c:770-805`, `lib/ladybug/ladybug_stubs.c:587-768`

`materialize_arrow_rows` acquires an Arrow schema and then loops over Arrow arrays. It releases the current array only after each chunk loop and releases the schema only at the end. But calls inside the loop, including `arrow_value`, `caml_copy_string`, `caml_alloc_tuple`, and nested Arrow decoding helpers, can raise via `caml_failwith` or allocation failure. On those paths, the function does not protect `array.release` or `schema.release`. The snippet shows the acquire/release pattern and in-loop calls. 

This is a C-stub resource leak under malformed Arrow data, OOM, or unexpected Arrow layouts.

### P1 — Ladybug direct query stubs do not check `caml_stat_strdup` before entering the C API

**Files:** `lib/ladybug/ladybug_stubs.c:808-820`, `lib/ladybug/ladybug_stubs.c:901-913`

Both `execute_direct` and `execute_direct_values` assign `char *cypher_copy = caml_stat_strdup(cypher)` and immediately call `api.connection_query(conn, cypher_copy, &result)` inside a blocking section. Unlike other helper paths in the same file that check allocation helpers, these functions do not handle `NULL` from `caml_stat_strdup`.  

Under allocation failure this can pass a null SQL pointer into the Ladybug C API.

### P1 — Turso prepare is a blocking SQLite operation but is not run in a blocking section

**Files:** `lib/turso/turso_stubs.c:283-300`

`eta_turso_prepare` calls `api.prepare_v2` directly on the OCaml runtime lock. The SQLite-backed `lib/sql/sqlite_stubs.c` prepare path copies the SQL string and uses a fuller error-handling path; Turso’s prepare allocates the custom statement block first and then calls `prepare_v2` without `caml_enter_blocking_section`. 

`sqlite3_prepare_v2` can block on schema locks, I/O, or virtual-table hooks. This can stall the OCaml runtime and is inconsistent with the rest of the database FFI design.

### P1 — SQLite/Turso column blob/text stubs collapse null/error cases into empty strings or uninitialized bytes

**Files:** `lib/sql/sqlite_stubs.c:559-604`, `lib/turso/turso_stubs.c:435-456`

The SQLite wrapper returns `caml_alloc_initialized_string(len, text == NULL ? "" : text)` for text and the same pattern for blob. Turso’s blob path allocates `len` bytes and copies only if `blob != NULL`; if `len > 0` and `blob == NULL`, the returned OCaml string/bytes contents are not initialized by the copy. 

The higher-level code may often consult column type first, but the C boundary should not silently turn a null native pointer into an empty value or partially initialized OCaml value. This is especially risky on OOM/error cases returned by SQLite APIs.

### P1 — WebSocket send/close state has a race that allows frames after close

**Files:** `lib/http/ws/ws_client.ml:24`, `lib/http/ws/ws_client.ml:318-360`

`send_frame_sync` checks `t.close_sent` before acquiring `write_mutex`. `send_close_frame_sync` sets `t.close_sent <- true` and then calls `send_frame_sync ~allow_after_close:true`. A normal sender can pass the pre-lock `close_sent` check, block on `write_mutex`, then write a data frame after the closer has sent or begun sending the close frame. The same area also uses `Stdlib.Random` for WebSocket masking.

The fix needs the close-state check and the write to be under the same critical section.

### P2 — SQL DSL is intentionally typed but not sound as a validity proof

**Files:** `lib/sql_dsl/eta_sql_dsl.mli:147-157`, `lib/sql/connection.mli:1-23`, `lib/sql_dsl/eta_sql_dsl_query.ml:27-32`

The DSL documentation admits the scope evidence “does not prove GROUP BY correctness, cardinality, correlation legality, uniqueness of aliases, or backend-specific coercion behavior,” and raw execution remains available through raw SQL APIs. The implementation also comments that raw escape hatches live outside the functor. 

That is not necessarily a bug if documented as “typed query construction,” but it means callers should not treat the DSL as a proof that generated SQL is valid or semantically safe. The package should maintain that distinction very clearly in public docs.

### P2 — Blocking timeout semantics are honest in docs but still easy to misuse with leased native resources

**Files:** `lib/eta/effect_blocking.ml:40-54`, `lib/duckdb/pool.ml:57-65`, `lib/eta/effect_concurrent.ml:68-98`

`blocking_result_timeout` is implemented as `race [ work; timer ]`, with cancellation checks only after the work result is returned. DuckDB correctly passes `on_cancel:(fun () -> Connection.interrupt conn)` and rejects `Detach_started` blocking pools for leased connections, but any connector that forgets a cooperative cancellation hook will only time out the caller’s wait, not the native operation.

This is mostly a design hazard, but it becomes correctness-sensitive for pools and native handles.

### P2 — `Channel.send` / `recv` expose wider internal result variants then assert impossible cases

**Files:** `lib/eta/channel.ml:356-369`

`send` maps `send_sync` and asserts false on `` `Full``; `recv` asserts false on `` `Empty``. These cases are intended to be impossible for blocking send/recv, but the public path still carries a wider result shape and crashes if an invariant is broken. 

This is not a demonstrated current bug, but it is brittle: if future changes introduce a missed state transition, users get `Assert_failure` rather than a typed channel failure.

---

## 2. Code Quality Review

### P2 — Several modules exceed 500 LOC and mix multiple responsibilities

**Files:** `lib/sql/sqlite_stubs.c` ~1022 LOC, `lib/ladybug/ladybug_stubs.c` ~992 LOC, `lib/duckdb/duckdb_stubs.c` ~976 LOC, `lib/sql_dsl/eta_sql_dsl_query.ml` ~934 LOC, `lib/stream/eta_stream.ml` ~817 LOC, `lib/ladybug/eta_ladybug.ml` ~783 LOC, `lib/otel/eta_otel.ml` ~750 LOC, `lib/ai/eta_ai.mli` ~730 LOC, `lib/sql/sqlite.ml` ~719 LOC, `lib/schema/eta_schema.ml` ~690 LOC, `lib/sql/migrate.ml` ~636 LOC, `lib/eta/effect.mli` ~634 LOC, `lib/eta/pool.ml` ~576 LOC, `lib/ai/anthropic/eta_ai_anthropic.ml` ~565 LOC, `lib/http/ws/ws_client.ml` ~526 LOC, `lib/sql_dsl/eta_sql_dsl.ml` ~508 LOC.

The most problematic are the C stubs and `eta_sql_dsl_query.ml`, because they combine memory management, protocol/API mapping, error conversion, and public semantics in a single audit unit. `lib/eta/pool.ml` even starts with a comment justifying keeping lifecycle, admission semaphore, and observability counters together, but at 576 LOC that coupling now makes shutdown and lease invariants hard to inspect. 

### P2 — `Eta.Pool` is over-coupled to lifecycle, semaphore admission, eviction, logging, metrics, and spans

**Files:** `lib/eta/pool.ml:1-80`, `lib/eta/pool.ml:531-574`

The module owns the pool state machine, semaphores, idle expiration, shutdown promises, logging, metrics, and span wrappers. This is high-risk because correctness bugs in one concern, such as shutdown timeout behavior, are entangled with observability and resource release. The top comment recognizes that close/release/eviction ordering is the invariant, but the code still lacks a smaller state-machine core that could be tested independently.

### P2 — Native database connectors duplicate pool/blocking logic

**Files:** `lib/duckdb/pool.ml:1-135`, `lib/sql/pool.ml:1-364`, `lib/turso/pool.ml`

DuckDB’s pool wrapper defines its own error translation, blocking wrapper, `Detach_started` rejection, timeout handling, query/select/execute wrappers, and shutdown behavior. Similar shapes exist in SQL and Turso pools. The consequence is visible in the DuckDB shutdown bug: connector-specific lifecycle choices are not centralized, so one pool wrapper can get parent/child shutdown ordering wrong while others do not.

### P2 — SQLite and Turso C stubs duplicate low-level SQLite binding and column extraction

**Files:** `lib/sql/sqlite_stubs.c:289-604`, `lib/turso/turso_stubs.c:283-456`

The two stubs implement similar prepare/finalize/bind/step/column logic, but with different safety properties: SQLite prepare copies SQL and has fuller memory checks; Turso prepare calls `prepare_v2` directly. Their column extraction logic is also similar but diverges in blob handling. 

This is an auditability problem: fixes in one backend can easily be missed in the other.

### P2 — The public `Effect` surface is too broad for a core abstraction

**Files:** `lib/eta/effect.ml:1-18`, `lib/eta/effect.mli:1-634`

`effect.ml` includes core, resource, concurrent, observability, supervisor, island, and blocking modules into a single public module. The `.mli` then documents all of that in one 600+ line facade. 

A facade can be useful, but this one makes it difficult to tell which semantics are fundamental to `Effect.t` and which are optional layers. It also increases the risk that internal helper constraints leak into the public abstraction.

### P2 — Runtime abstraction uses audited erasure, but the safety boundary is still very sharp

**Files:** `lib/eta/runtime_core.ml:23-45`, `lib/eta/runtime_erasure.ml:1-16`

Typed failures cross fibers through `Obj.repr` and `Obj.obj` guarded by a dynamic `Typed_fail` key. `Runtime_erasure` also uses `%identity` casts for island/blocking pools and `Obj.magic` to erase runtime error type. The comments are careful and the erasure is centralized, which is good, but the design has a very small trusted core with high blast radius.

This should remain isolated and heavily tested; feature modules should not grow additional erasure sites.

### P2 — AI provider facades are mostly pass-through aliases

**Files:** `lib/ai/openai/eta_ai_openai.ml:1-63`, `lib/ai/openrouter/eta_ai_openrouter.ml:1-87`

The OpenAI and OpenRouter facades are dominated by `include Common`, endpoint aliases, and tiny wrapper modules that rename `run` to `generate`, `create`, or `responses`.

This creates a wide API surface without much semantic ownership. It also spreads endpoint behavior across `Common`, endpoint implementation modules, provider records, and facade aliases.

### P2 — Provider capability flags are centralized but not structurally tied to endpoint implementations

**Files:** `lib/ai/openai/common.ml:34-83`, `lib/ai/openrouter/common.ml:171-216`

Capabilities are record literals separate from the endpoint modules. OpenRouter advertises many task capabilities in one record, then endpoint helpers live separately. 

This is maintainability-sensitive: adding/removing endpoint support requires updating both the implementation and the capability record, with no type-level tie between the two.

### P2 — SQL DSL clearly documents its limits, but the public API may invite overconfidence

**Files:** `lib/sql_dsl/eta_sql_dsl.mli:147-157`, `lib/sql/connection.mli:1-23`

The DSL docs are unusually honest about not proving several SQL validity properties and about raw SQL bypasses. That is good. The code quality issue is that the library markets a typed DSL but still exposes raw execution paths and compiled SQL access. Callers can easily blur “typed construction” with “valid SQL proof.” 

### P3 — Naming and endpoint style are inconsistent across packages

**Files:** `lib/duckdb/connection.ml`, `lib/sql/connection.mli`, `lib/ai/openai/eta_ai_openai.ml`, `lib/ai/openrouter/eta_ai_openrouter.ml`

Examples include `open_`, `open_memory`, `connect`, `run_schema`, `exec_script`, `messages`, `responses`, `chat_completions`, `create`, `generate`, and `run`. Some naming reflects provider vocabulary, but across the repository it increases cognitive load and makes discovery harder.

---

## 3. AI Slop Review

I am using “AI slop” as a code-smell category here, not as a claim about authorship.

### P2 — “Safety by comment” appears around the riskiest abstraction boundaries

**Files:** `lib/eta/runtime_erasure.ml:1-16`, `lib/eta/pool.ml:1-5`, `lib/sql_dsl/eta_sql_dsl_query.ml:27-32`

Several comments explain why unsafe or large designs are acceptable: runtime erasure is “audited,” pool state must stay in one module, and SQL rendering stays behind one functor boundary. These comments are not wrong, but they are doing heavy assurance work that should ideally be backed by smaller modules and tests.

This is a common unreviewed-generated-code smell: the comment explains the intended invariant, while the code still leaves the invariant hard to verify.

### P2 — Facade modules add many names with little semantic value

**Files:** `lib/ai/openai/eta_ai_openai.ml:1-63`, `lib/ai/openrouter/eta_ai_openrouter.ml:1-87`

The provider facades mostly alias endpoint implementations and rebuild tiny one-function modules. The pattern looks polished, but it adds namespace bulk without much logic.

This kind of wrapper proliferation is a typical “looks complete” pattern that increases API surface and maintenance without reducing complexity.

### P2 — Defensive impossible-case handling leaks into public paths

**Files:** `lib/eta/channel.ml:356-369`

`send` and `recv` use `assert false` for variants that should be unreachable. The problem is not the invariant itself; it is that the internal result type is broader than the public function needs, so impossible cases are carried forward and then asserted away. 

This is a small but recurring slop smell: use a broad defensive type, then silence the extra cases instead of narrowing the internal API.

### P2 — Optional portable-island/H3 direction appears partially productized while research notes still frame it as experimental

**Files:** `lib/eta/effect_island.ml`, `lib/eta/island_runtime.ml`, `lib/eta/effect.mli`; context file `Branch · H3 runtime comparison.txt`

The code already contains `Effect.Island` and island runtime pieces, while the research note argues for keeping islands explicit, batch-only, and much smaller than a full H3 rewrite. The research note’s allowed scope is “Island scheduler, portable callback, portable input/output, indexed batch result, materialized worker failure,” and explicitly excludes portable Resource/Supervisor/Stream/OTel/full `Effect.Portable`. 

The code mostly follows that direction, but the presence of islands inside the main `Effect` facade makes the boundary less visually experimental. That can make future scope creep easier.

### P3 — Many comments restate module intent rather than sharpening invariants

**Files:** `lib/eta/effect.mli:1-40`, `lib/ai/openai/eta_ai_openai.ml:1-3`, `lib/ai/openrouter/eta_ai_openrouter.ml:1-2`

There are many high-level comments like “facade preserving endpoint-oriented public names” or broad docs explaining `Effect.t`. Some are useful, but many restate obvious structure rather than documenting precise failure, cancellation, or ownership invariants.

Given this codebase’s risk profile, invariant-heavy documentation would be more valuable than facade-intent prose.

### P3 — Repeated provider boilerplate creates the impression of coverage without proving behavior

**Files:** `lib/ai/openai/common.ml`, `lib/ai/openrouter/common.ml`, endpoint modules under `lib/ai/openai/` and `lib/ai/openrouter/`

Patterns like `default_provider`, `request`, `run`, `stream`, `encode_*`, `decode_*`, and small endpoint modules repeat across providers. This repetition is not inherently wrong, but it can hide subtle differences in streaming, error decoding, capability flags, and binary-body handling behind nearly identical code.

### P3 — The SQL DSL mixes strong type-language claims with broad escape-hatch reality

**Files:** `lib/sql_dsl/eta_sql_dsl.mli:147-157`, `lib/sql/connection.mli:1-23`

The docs explicitly say the DSL does not prove many SQL validity rules and that raw APIs bypass it, which is honest. The slop smell is the mismatch between a large typed DSL surface and the number of validity properties intentionally left outside it. 

This should be presented as “typed construction and decoding assistance,” not “type-safe SQL” in any broad sense.

---

## Highest-priority repair targets

The first repairs I would prioritize are:

1. DuckDB pool shutdown ordering with deadline timeouts.
2. Synchronization/lifecycle fences around DuckDB database and connection handles.
3. `Effect.finally` cancellation cleanup failure preservation.
4. C-stub safety pass for Ladybug, Turso, SQLite, and DuckDB under OOM, null native pointers, and exception cleanup.
5. WebSocket close/send locking.

Those are the areas most likely to produce real user-visible corruption, leaks, hidden cleanup failures, or native crashes.
