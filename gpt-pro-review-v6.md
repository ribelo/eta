# 1. Correctness Review

## P0 — C stub length truncation can corrupt or mis-bind large text/blob parameters

`lib/sql/sqlite_stubs.c` validates SQL string length before `sqlite3_prepare_v2`, but the bind paths do not perform the same check: `eta_sqlite_bind_text` and `eta_sqlite_bind_blob` cast `caml_string_length` directly to `int`.   `lib/turso/turso_stubs.c` repeats the same pattern for `bind_text` and `bind_blob`. 

For payloads larger than `INT_MAX`, this can truncate or become negative. For SQLite text, negative lengths have different semantics; for blobs, negative length is unsafe/undefined at the SQLite API boundary. This is the strongest correctness/security issue I found in the package.

## P1 — `blocking_result_timeout` is not a hard timeout for started blocking work

The public `blocking_result_timeout` implementation races the blocking job against a timer.  But blocking jobs are explicitly cancellation-protected while running in the default `Drain` path, and the public docs admit started callbacks are not preempted; they must finish, use `Detach_started`, or cooperate through `on_cancel`.  

This means callers may reasonably read “timeout” as a hard deadline, while the implementation can only enforce an advisory deadline for jobs that either have not started or can be cooperatively interrupted. This is especially risky around DB/FFI calls, because several pool APIs expose `timeout` parameters over blocking operations.

## P1 — `Domain_isolated` blocking pool accepts nonportable closures by construction

The code explicitly suppresses OxCaml domain-safety alerts and uses `Domain.spawn` for a callback whose public type is ordinary `unit -> 'a`, not `@ portable`. The comment states that `Domain.Safe.spawn` is not used because it would require a portable callback and that the safety invariant is “operational rather than type-level.”  The public docs likewise warn that callbacks must not capture Eio handles, Eta runtime state, or values unsafe across domains, while admitting the type cannot express that. 

That is a real unsoundness boundary. It may be acceptable as an escape hatch, but it should be treated as unsafe FFI-like API surface, not as a normal pool constructor.

## P1 — Pool shutdown can block new acquisitions behind active permits instead of failing promptly

`Eta.Pool.reserve` checks `t.shutting_down`, but that check happens only after a semaphore permit is acquired.  The state machine enters `Acquire_permit` by calling `Semaphore.acquire` first, then transitions to `Reserve_slot`.  Shutdown sets `shutting_down` and closes idle entries, then waits until active count reaches zero. 

If the pool is saturated when shutdown begins, a new `with_resource` caller can sit in the semaphore queue until an active resource releases, rather than immediately receiving `Pool_shutdown`. In the presence of a stuck active resource, that waiter can hang behind shutdown. The intent appears to be “stop accepting new work”; the admission check is in the wrong phase for that guarantee.

## P1 — SQLite typed `int` decoding silently truncates 64-bit integer values

The SQLite C stub implements `eta_sqlite_column_int` by reading `sqlite3_column_int64` and casting the result to OCaml `intnat`.  The typed SQL `int` decoder uses `Sqlite.column_int` directly, so values outside OCaml `int` range are not rejected; they are converted through the stub. 

Other parts of the code know how to range-check dynamic integer values before choosing `Int` vs `Int64`, which makes the typed `int` path especially suspect. Turso’s row materializer does the safer range check pattern. 

## P1 — Ladybug Arrow materialization trusts buffer layout too much

`ladybug_stubs.c` directly dereferences Arrow array buffers in `arrow_i64`, `arrow_f64`, `arrow_bool`, and `arrow_string` without checking `n_buffers`, child count, or nullness of the required buffers.  The materializer then iterates `schema.children` and `array.children` directly. 

If the Ladybug library returns malformed Arrow data, unexpected dictionary/extension layout, or an error path with partially initialized arrays, this can segfault the OCaml process. Even if the upstream library is trusted, C stubs should defend against null buffers at ABI boundaries.

## P1 — DuckDB database close stops after the first connection-close error, leaking later connections

DuckDB `Database.close` walks `db.connections` through `close_connections`, but `close_connections` aborts on the first close error and does not attempt to close the remaining connections.  `Database.close` then returns the error without closing the database handle. 

That means one bad connection close can leave the database and remaining connections open. For a lifecycle API, best effort should usually close all children, aggregate or suppress errors, then close the parent if safe.

## P2 — DuckDB result materialization has unchecked C/OCaml allocation and null assumptions

DuckDB blob materialization allocates an OCaml string with `(mlsize_t)blob.size` without checking whether the DuckDB `idx_t` size fits OCaml’s string size.  Row materialization also calls `caml_copy_string(api.column_name(...))` without a null fallback, unlike other stubs that explicitly convert null names to `""`. 

These are less likely than the SQLite/Turso bind-length issue, but they are still C-stub robustness bugs.

## P2 — Island pool shutdown state is unsynchronized

`Island_runtime.pool` stores `mutable stopped : bool`; `Pool.shutdown` mutates it directly, and `ensure_running` reads it before submitting jobs.  The submit paths call `ensure_running` and then enqueue onto the parallel pool. 

If an island pool is shared across fibers/domains, submit and shutdown can race. The public API presents a reusable pool, so this should be protected by a mutex/atomic state or documented as single-owner only.

## P2 — `Effect.catch` loses information when multiple branches are caught

`catch_causes` walks a sequential/concurrent cause tree and returns the first caught value while discarding later caught values. If at least one branch is uncaught, caught branches are also discarded and only uncaught causes are recombined. 

This may be intentional, because `catch` returns a single value. But for concurrent causes it means recovery is order-sensitive and can erase evidence that several typed failures were handled. This is a semantic footgun for a library that otherwise invests heavily in preserving `Sequential`, `Concurrent`, and `Suppressed` cause structure.

## P2 — The SQL DSL is type-aided, not type-enforced, and the package exposes raw bypasses

The public SQLite docs explicitly say the typed DSL is not a closed enforcement boundary and that `Pool.Raw` exists for raw SQL escape hatches.  `Pool.Raw` exposes raw `query`, `fold`, `execute`, `execute_script`, and `with_connection`, each documented as bypassing the typed DSL.  

So the answer to “can the typed DSL be bypassed?” is yes, deliberately. That is acceptable if framed as an escape hatch, but it means any soundness claim must be scoped to code that stays inside `Typed`/compiled query builders.

# 2. Code Quality Review

## P1 — The core type-erasure boundary is spread across too many modules

Typed failures are packed through `Obj.t` exceptions in `Runtime_core`; the runtime bridge uses `%identity` to reinterpret public abstract types, and `Runtime.run_effect` uses `Obj.magic` to erase the runtime failure carrier.   

The code comments are aware of the danger, but the design still requires maintainers to reason across `Runtime_core`, `Effect_core`, `Runtime`, and private modules to preserve the dynamic-key invariant. This should be isolated behind a tiny audited module with minimal exports.

## P1 — `Effect.mli` exposes too much implementation machinery

The public `Effect` signature starts with basic combinators, then exposes the full supervisor-scope GADT, island APIs, blocking pools, tracing/logging/metrics hooks, finalization, background fibers, and private extension hooks in one file. The supervisor GADT alone appears at the top-level public signature rather than being hidden behind `Supervisor`.  The implementation mirrors this by `include`-ing all internal effect submodules into one public module. 

This makes `Effect` the architectural center of gravity for nearly everything. It hurts module boundaries and makes it harder to reason about which parts are algebra, runtime integration, observability, or structured concurrency.

## P1 — Several public or critical modules are too large to review safely

The package contains many >500 LOC modules. The largest and most risk-relevant are C stubs and core DSL/runtime modules: `lib/sql/sqlite_stubs.c` is 998 LOC, `lib/ladybug/ladybug_stubs.c` is 966 LOC, `lib/duckdb/duckdb_stubs.c` is 887 LOC, `lib/sql_dsl/eta_sql_dsl_query.ml` is 929 LOC, `lib/stream/eta_stream.ml` is 817 LOC, `lib/eta/pool.ml` is 552 LOC, `lib/eta/blocking_runtime.ml` is 520 LOC, and `lib/eta/effect.mli` is 646 LOC.        

The most justified splits are: C stub loading vs handle finalization vs binding vs row materialization; SQL expression/schema/rendering/compilation; pool admission vs close/eviction vs metrics; stream constructors/combinators/sinks.

## P2 — `Eta.Pool` is intentionally monolithic, but the invariants are too dense

`pool.ml` begins with a comment justifying keeping lifecycle state, admission semaphore, and observability counters in one module because transition ordering is the invariant.  The module then stores all lifecycle counters/state directly in one record.  Acquisition, release, close, health, shutdown, and metrics all interleave in the same state machine.   

The comment is correct that transition authority matters, but the result is difficult to audit. A smaller internal transition module plus separate effectful “actions” would preserve a single authority without mixing every concern into one file.

## P2 — AI provider endpoints repeat the same request/run/stream shape

OpenAI Chat Completions, OpenAI Responses, and OpenRouter Responses all implement the same structure: choose provider, encode request, build request, run or stream.   

Some duplication is structural because provider envelopes differ, but the repeated plumbing should be pushed into a small endpoint builder. The current pattern increases the chance of inconsistent span wrapping, stream flag handling, error mapping, or provider defaulting.

## P2 — Facade modules add a lot of alias churn

`eta_ai_openai.ml`, `eta_ai_openrouter.ml`, and `eta_sql.ml` are largely re-export maps.   

Facade modules are useful, but these are heavy enough that they become another API surface to keep synchronized. The pattern is especially noisy where a module just wraps another module’s function under the same conceptual name.

## P2 — The SQL DSL functor mixes too many layers

`eta_sql_dsl_query.ml` defines backend requirements, table/column metadata, expression AST-as-SQL-string, projections, sources, select/insert/update/delete compilation, and schema integration in one functor.   

This makes the DSL hard to test in isolation. It also blurs “typed query representation” with “SQL rendering,” which is exactly where soundness and invalid-SQL bugs tend to hide.

## P2 — `eta_ai.mli` is a vocabulary, transport, stream, toolkit, provider, and observability API in one file

The AI core signature begins with JSON helpers and common data types, then toolkits, SSE stream types, provider capabilities, transport request builders, stream operations, and observability span wrappers.  

This is maintainable while small, but it is already 728 LOC. Splitting stable data vocabulary from transport and provider helpers would reduce accidental dependency coupling between providers, HTTP, SSE, and observability.

# 3. AI Slop Review

## P1 — Dangerous implementation choices are justified with prose instead of made unrepresentable

The strongest “AI slop” smell is not syntax; it is the pattern of long comments rationalizing unsafe boundaries. The `Domain_isolated` comment explicitly says the safe spawn API is not used because the public API does not enforce portability, then declares an operational invariant instead.  The public docs repeat that users must not capture unsafe values because the type cannot express the rule. 

That reads like a design hole being papered over by documentation. For an OxCaml library, “must not capture Eio handles” should be a type boundary where possible, not a comment.

## P2 — Public documentation often restates signatures or internal implementation history

There is a lot of documentation that repeats obvious facts or embeds version/history notes rather than giving durable API contracts. Examples: `eta_ai.mli` says raw JSON is kept “until eta-schema gains JSON export,” toolkits store raw JSON in “v1,” and island worker diagnostics are “v1” and “intentionally smaller than Cause.t.”   

Those notes may be true, but they age poorly and make the API feel provisional. Stable docs should describe the contract, not the migration backlog.

## P2 — Boilerplate wrappers create “looks complete” surfaces with little behavior

Provider facades expose many endpoint modules whose functions only forward to another binding. For example, OpenAI’s `Images`, `Speech`, and `Transcriptions` modules each define a one-function wrapper around the top-level function.  OpenRouter repeats the same pattern across `Speech`, `Images`, `Transcriptions`, `Rerank`, and `Video`. 

This is a classic over-generated API smell: it makes the surface look richer without adding semantics. It also creates more names to document, test, and keep compatible.

## P2 — Helper boilerplate is repeatedly reintroduced instead of centralized

`Eta_ai.Json_helpers` defines `decode_error_result`, `parse_json`, `schema_value`, and `result_all`.  Provider codec modules then wrap or alias these helpers under provider-specific names, while other modules define similarly shaped validation helpers. 

Some provider-specific wrapping is useful for error labels, but the repeated `unsupported`, `non_empty_list`, `result_all`, and encode/decode wrapper pattern feels mechanically generated. It increases churn without much domain modeling.

## P2 — Over-engineered “facade over facade” layering obscures the real module boundaries

`eta_sql.ml` aliases error types, primitive type constructors, table/column types, runtime modules, DSL modules, and execution modules in a single facade.  `eta_ai_openai.ml` and `eta_ai_openrouter.ml` do the same for provider endpoints.  

This style is not wrong in OCaml, but here it appears systematic and expansive. It creates an API catalogue rather than a small set of carefully designed entry points.

## P3 — No obvious TODO/commented-out-code detritus was present

I did not find obvious `TODO`, `FIXME`, `XXX`, or commented-out-code artifacts in the packaged source. The slop signals are more architectural: verbose explanatory comments, duplicated wrappers, broad facades, and provisional “v1” language.

# Highest-priority repair order

The first repairs I would prioritize are the C stub length/overflow/null checks, then the blocking timeout/cancellation contract, then the unsafe `Domain_isolated` boundary. After that, I would split the largest C stubs and the SQL DSL functor, because those are the places where review difficulty is already turning into correctness risk.
