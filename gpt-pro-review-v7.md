## 1. Correctness Review

### P0 — Blocking timeouts can return pooled DB resources while detached C work is still running

`lib/duckdb/pool.ml:35-45, 61-91` and `lib/sql/pool.ml:33-37, 86-100` run blocking database operations under `Eta.Effect.blocking_result_timeout` with an `on_cancel` interrupt hook. The underlying blocking runtime’s `Detach_started` policy explicitly marks a started job as detached and raises cancellation while the worker promise keeps running (`lib/eta/blocking_runtime.ml:337-371`). Since `DuckDB.Pool.query/select/execute/...` and SQL pool operations are wrapped in `Eta.Pool.with_resource`, a timeout/cancellation can allow the pool lease to end while the systhread is still using the same connection. That is a connection reuse/close race and can become use-after-close or concurrent use of a non-thread-safe DB handle.

This is highest priority because the code exposes `?blocking_pool` on DB operations, and the docs even mention `Detach_started` as an option for started calls. For pooled FFI resources, detached work needs resource quarantine until the worker actually finishes, or the pool must reject `Detach_started` for leased resources.

### P1 — DuckDB appender failure paths can corrupt appender state and leak handles

`lib/duckdb/duckdb_stubs.c:835-858` appends each value to the DuckDB appender as it traverses the OCaml list. If one later append fails, the function raises before `duckdb_appender_end_row`; the appender has already consumed a partial row and there is no reset/abort path. Subsequent appends can observe corrupted appender state. `lib/duckdb/duckdb_stubs.c:873-890` also raises immediately if `duckdb_appender_close` fails, before `duckdb_appender_destroy` and before nulling the pointer, so explicit close failure leaves cleanup to the finalizer and keeps the OCaml wrapper logically open.

### P1 — C stubs rely on finalizers for last-resort cleanup, but finalizers perform potentially blocking DB destruction in the OCaml runtime

The SQLite, Turso, DuckDB, and Ladybug stubs all use custom finalizers to close/destroy DB or statement handles. SQLite and Turso explicitly comment that finalizers cannot enter blocking sections and are only last-resort cleanup paths; DuckDB has the same pattern for database, connection, appender, and result-owner finalizers; Ladybug destroys database and connection handles directly from finalizers (`lib/sql/sqlite_stubs.c:21-43`, `lib/turso/turso_stubs.c:75-94`, `lib/duckdb/duckdb_stubs.c:47-84`, `lib/ladybug/ladybug_stubs.c:109-126`).

This is not automatically wrong as a last-resort fallback, but it means leaked handles can block the OCaml finalizer path, and cleanup success depends on users always taking explicit close paths. For database libraries, that is a real reliability hazard.

### P1 — DuckDB C allocation/error paths are not consistently cleanup-safe

`lib/duckdb/duckdb_stubs.c:704-724` uses `caml_stat_strdup` in `eta_duckdb_exec_script` without checking for `NULL` before entering `api.query`. Other paths copy foreign-owned data into OCaml values and can call `caml_failwith` while foreign allocations are live; for example `value_blob`/`value_varchar` conversion around `lib/duckdb/duckdb_stubs.c:245-305` should be audited so every `api.free_ptr` and `api.destroy_result` is paired even if OCaml allocation raises. The file already uses a result owner for query results, which is good, but individual value-conversion paths still need RAII-style cleanup discipline.

### P1 — `finally` can turn cancellation into a normal effect failure when cleanup fails

In `lib/eta/effect_resource.ml:34-41`, if the body is cancelled and cleanup fails, `finally` returns `Exit.Error (Cause.suppressed ~primary:Cause.interrupt ...)` instead of re-raising the original `Eio.Cancel.Cancelled`. That makes a cancellation-plus-cleanup-failure look like an ordinary Eta failure to enclosing combinators. In structured concurrency, cancellation should generally remain cancellation, with cleanup failure recorded diagnostically rather than making the cancelled fiber recoverable by typed-error handlers.

### P1 — `race` and `timeout_as` can drop losing-child cleanup/finalizer causes

`lib/eta/effect_concurrent.ml:68-98` makes the first successful `race` child set `winner`, fail the switch, and then await cancellation; losing children are cancelled and their cancellation/finalizer failures are not incorporated into the returned success. `lib/eta/effect_core.ml:285-331` tries to preserve a body failure if `timeout_as` loses to the timer and `body_result` is already set, but if timeout wins before cleanup/finalizer results materialize, the timeout path returns only the timeout failure.

The user-visible issue is weak cause chains: finalizer failures from cancelled losers can disappear exactly where diagnostics matter most.

### P1 — The DuckDB typed bulk API is not actually row-shape safe

`lib/duckdb/bulk_row.ml:5-9` defines a phantom-typed row as just `Value.t list`. `value` appends `column_value`, while `null _column` ignores the column entirely and appends raw `Value.Null`. `Bulk.append_row` then forwards the list to the appender. This means the API does not enforce required columns, column order, duplicate columns, row width, or nullability. A typed caller can build a row that compiles but fails at runtime or inserts values into the wrong columns. 

### P1 — AI/HTTP provider error bodies are read without any size cap

`lib/ai/transport.ml:64-69` supports `?max_bytes`, and success paths in `perform_raw`/`perform_binary` honor it. But error paths in `perform_raw`, `perform_binary`, `perform_chat`, `perform_embeddings`, and `perform_stream` call `read_response_text response.body` without passing a cap (`lib/ai/transport.ml:85-162`). A malicious or broken provider can return a huge non-2xx body and force unbounded memory use before `decode_error` runs.

### P2 — SQL DSL validity is explicitly bypassable and should not be described as a soundness boundary

`lib/sql/connection.mli:1-25` exposes `Raw.query`, `Raw.execute`, `Raw.execute_script`, and `Raw.prepare_migration`, with documentation saying these operations bypass the typed SQL DSL and put SQL validity, parameter ordering, and decoding on the caller. The SQL DSL functor also states that raw escape hatches live outside it (`lib/sql_dsl/eta_sql_dsl_query.ml:27-32`).

That is a legitimate escape hatch, but it means the project should avoid claims like “the typed DSL cannot produce invalid SQL” unless scoped to specific builders and excluding raw operations. For public API design, `Raw` probably belongs under an `Unsafe` or visibly quarantined module.

### P2 — DuckDB connection bookkeeping is unsynchronized mutable state

`lib/duckdb/connection.ml:8-22` mutates `database.connections` on connect/close, and `lib/duckdb/database.ml:19-41, 72-83` filters and iterates that list during database close. There is no mutex around this state. If the same `database` is used concurrently from multiple fibers/domains, connection list updates can race with close, leak connections, or close a live connection twice. 

### P2 — Channel observability stats can lie about effective capacity

`lib/eta/channel.ml` tracks `pending_receivers` as part of `capacity_used = depth + pending_receivers`, but `stats.depth` reports only `depth`. A channel can therefore appear empty while capacity is actually reserved by delivered-but-unclaimed receiver handoffs. This is not necessarily a data loss bug, but it is a production debugging hazard for backpressure and stuck-sender incidents. The pending-delivery path is visible in `deliver_receiver`, `claim_receiver`, and `cancel_receiver` (`lib/eta/channel.ml:100-156, 170-233`).

## 2. Code Quality Review

### P1 — The public `Effect` surface exposes internal supervisor AST machinery

`lib/eta/effect.mli:25-53` publicly exposes the full `supervisor_scope` GADT constructors, and `lib/eta/effect.mli:446-475` exposes constructor wrappers. The implementation comment says the AST is deliberate because it prevents child handles from escaping (`lib/eta/effect_supervisor_scope.ml:1-11`), but putting the AST in the public signature locks users to an internal interpreter representation.

This is the largest API design concern. If the supervisor representation needs to change, the public ABI and user pattern matches are already coupled to it. A smaller callback-based or abstract scope interface would leave more room to evolve the runtime.

### P2 — Several modules are too large to review or maintain as single units

The largest file is `lib/sql_dsl/eta_sql_dsl_query.ml` at 935 LOC, and the file itself says it intentionally keeps expression construction, SQL rendering, and row decoding behind one backend contract (`lib/sql_dsl/eta_sql_dsl_query.ml:27-32`). Other large modules include `lib/sql/sqlite_stubs.c` at 1021 LOC, `lib/ladybug/ladybug_stubs.c` at 993 LOC, `lib/duckdb/duckdb_stubs.c` at 891 LOC, `lib/stream/eta_stream.ml` at 818 LOC, `lib/otel/eta_otel.ml` at 751 LOC, `lib/sql/sqlite.ml` at 720 LOC, `lib/schema/eta_schema.ml` at 685 LOC, `lib/eta/effect.mli` at 650 LOC, `lib/sql/migrate.ml` at 637 LOC, and `lib/eta/pool.ml` at 577 LOC.

The SQL DSL in particular should likely be split into identifiers/rendering, expressions, projections/scopes, DML builders, and compilation. The C stubs should be split by dynamic loader, handle types, value conversion, prepared execution, and appenders.

### P2 — `Effect.ml` is a wide include-based facade over implementation modules

`lib/eta/effect.ml:1-10` opens `Effect_core` and includes `Effect_core`, `Effect_resource`, `Effect_concurrent`, `Effect_observability`, `Effect_supervisor_scope`, `Effect_island`, and `Effect_blocking`. That keeps the public module compact syntactically, but it also makes name ownership, dependency direction, and API review harder; every internal include can accidentally widen the public implementation surface. 

### P2 — AI provider facades have high wrapper duplication

OpenRouter’s facade is mostly aliasing endpoint implementation functions into public names and one-method provider modules (`lib/ai/openrouter/eta_ai_openrouter.ml:1-80`). OpenAI and OpenAI-compatible follow the same general shape. This duplication is partly structural, but repeated request/run/stream wrappers, capability records, auth headers, and module aliases create drift risk when provider behavior changes.

### P2 — Raw SQL escape hatches are too close to the typed API

`Connection.Raw` lives beside `Connection.Typed` in the internal SQLite connection API, and the docs explicitly say raw operations bypass typing (`lib/sql/connection.mli:1-25`). Because the library markets a typed DSL, the raw path should be visually quarantined more aggressively, either in an `Unsafe` namespace or a separate lower-level connector module.

### P2 — `Host_eio` is a heavy abstraction for a narrow integration problem

`lib/eta/host_eio.ml/.mli` defines module types for `UNIX`, `TIME`, `NET`, `FLOW`, `SWITCH`, `FIBER`, `CANCEL`, and aggregates them into `EIO`, then stores first-class modules in a record. The docs say this is for toplevel-sensitive integrations, mainly `dune utop` workflows (`lib/eta/host_eio.mli:1-80`).

That may be necessary for utop, but it is a lot of surface area for a compatibility shim. Keep it isolated and avoid allowing it to become the normal dependency-injection pattern for runtime internals.

### P3 — Channel close is synchronous while send/recv are effects

`Channel.send` and `Channel.recv` are `Effect.t` operations, while `Channel.close` and `Channel.close_with_error` are direct synchronous functions using `Eio.Mutex` internally. This is not wrong, but the API makes close look cheaper/safer than it is and differs from the rest of the concurrency surface. A close operation that can lock and resolve waiters is arguably effectful and should follow the same style.

### P3 — Interface documentation is extensive enough to obscure the core contracts

`lib/eta/effect.mli` is 650 LOC and has long explanatory blocks for many operations, including `catch`, `finally`, `acquire_release`, observability, and `Private` hooks (`lib/eta/effect.mli:346-420, 606-649`). Some of that documentation is valuable, but the volume makes it harder to spot the actual API and the few critical behavioral caveats.

## 3. AI Slop Review

### P2 — “Typed” phantom wrappers that do not enforce their advertised invariant

`lib/duckdb/bulk_row.ml:5-9` is a classic plausible-but-thin abstraction: `type 'table t = Value.t list`, plus functions that merely append values. The phantom `'table` suggests row/table safety, but the implementation does not track columns or row shape. This looks like an abstraction added for API aesthetics rather than enforced semantics. 

### P2 — Magic numeric C type tags are used where named constants are required

DuckDB value/appender conversion switches on raw tags such as `case 6`, `case 7`, `case 8`, `typ == 19`, `typ == 23`, etc. (`lib/duckdb/duckdb_stubs.c:245-305, 758-823`). This is the kind of code that looks plausible but is brittle against upstream enum changes and hard to audit. Named constants or generated bindings would make type mapping reviewable.

### P2 — Facade modules repeat endpoint names without adding behavior

OpenRouter’s public facade repeats aliases like `responses_request = Responses_impl.request`, `embeddings = Embeddings_impl.run`, and then wraps them again inside `module Chat`, `module Embeddings`, `module Speech`, `module Images`, etc. (`lib/ai/openrouter/eta_ai_openrouter.ml:1-80`). OpenAI has a similar one-line wrapper pattern. These facades may preserve public names, but they carry the smell of generated glue that should be mechanically derived or centralized. 

### P2 — The SQL DSL has a defensive comment explaining why a 935-line functor remains monolithic

`lib/sql_dsl/eta_sql_dsl_query.ml:27-32` says splitting expression construction, SQL rendering, and decoding would require exposing a second public contract, so all layers remain in one functor. That may be true today, but the comment reads like a justification for avoiding a cleaner internal architecture. A private internal AST does not have to be public, and the current size invites accidental coupling. 

### P3 — “Internal: see Effect for the public surface” comments are repeated boilerplate

Several internal modules start with comments like “Internal: see Effect for the public surface,” for example `effect_resource`, `effect_blocking`, `effect_concurrent`, and `effect_island`. The comments are harmless, but they are repetitive and add little beyond what Dune private modules and module names already say.

### P3 — Documentation sometimes restates the type signature rather than sharpening the contract

Examples include `Effect.sync` (“lifts an OCaml function into an effect”), `named` (“attaches a span name”), and several provider endpoint comments. The better comments are the ones that state surprising behavior, such as non-preemptive cancellation or raw SQL bypasses. The rest can be shortened so the important warnings stand out.

### P3 — Over-defensive pass-through error plumbing appears throughout provider code

Provider modules repeatedly use pass-through patterns like `Stdlib.Error _ as error -> error`, `Option.value ~default`, and small wrappers around common codec functions. This is not a correctness bug, but across OpenAI-compatible/OpenRouter/OpenAI it reads like generated defensive boilerplate rather than a minimal hand-designed provider layer.

## Highest-priority repair shortlist

The first repairs I would line up are: make blocking-pool `Detach_started` incompatible with pooled resources or quarantine leased resources until worker completion; harden DuckDB appender and C cleanup paths; cap all HTTP error-body reads; fix cancellation/finalizer cause preservation in `finally`, `race`, and `timeout_as`; and either enforce real row-shape invariants in `DuckDB.Bulk_row` or remove the phantom safety signal.
