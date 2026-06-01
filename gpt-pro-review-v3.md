
## Source and scope note

I reviewed the uploaded Repomix package as the source of truth. The package itself says it is **pure library only** and excludes tests, benchmarks, audit, docs, probes, and some dedicated test/bench packages, so I could review implementation and interfaces but not verify behavior against the missing test corpus.  The separate H3/portable-islands note was useful only as design context, especially for the intended “small explicit island, not full rewrite” direction. 

No P0 issue stood out from this pass. The highest-risk findings are P1 correctness and lifecycle issues.

---

# 1. Correctness Review

## C1. P1 — `Effect.Island.*` blocks the Eio domain and likely makes timeout/cancellation claims false

**Files:** `lib/eta/effect_island.ml:28-44`, `lib/eta/island_runtime.ml:75-85`, `lib/eta/par_runtime.ml:134-196`, `lib/eta/effect.mli:104-110`

`Effect.Island.map`, `map_result`, and `all_settled` call `Island_runtime.submit_*` synchronously inside the current Eta effect interpreter. Those functions call `Par.Pool.run_many_on_workers`, which waits with `Mutex`/`Condition.wait` until all jobs finish. That wait is not expressed as an Eio effect and does not yield to the Eio scheduler.

This directly conflicts with the public docs, which say parent cancellation or Eta timeout can stop waiting for the batch. In practice, if the caller’s Eio domain is blocked in `Condition.wait`, the timeout fiber may not run and cancellation may not be observed promptly. This is especially risky because the API is documented as CPU offload, but the coordinator wait path is still synchronous.

This also matters relative to the H3 research goals: the research note explicitly treats portable islands as finite-batch and cancellation-honest, not preemptive. The code mostly adopts that shape, but the coordinator wait should not block the effect runtime. 

---

## C2. P1 — Global `fiberless_frame` can cross-contaminate runtimes/domains

**File:** `lib/eta/effect_core.ml:23-67`

`effect_core.ml` stores the current Eta runtime frame in `frame_key` when there is Eio fiber context, but falls back to a global mutable `fiberless_frame : frame option ref` outside fiber context. `current_frame` reads that global, and `with_fiberless_frame` saves/restores it with ordinary mutation.

That global ref is not domain-local and is not protected by a mutex. Concurrent uses of Eta from multiple domains, or nested host-Eio/toplevel paths, can observe the wrong frame. The effects are serious: typed failures can be decoded with the wrong `fail_key`, finalizers can register against the wrong runtime boundary, and observability/runtime services can leak across logically separate runs.

The code tries to bridge “no Eio fiber context” use cases, but a global mutable fallback is not safe for an OCaml 5/OxCaml library that also exposes domain/parallel primitives.

---

## C3. P1 — `Effect.catch` can silently drop information from composite causes

**File:** `lib/eta/effect_core.ml:199-240`

`catch_cause` recursively handles `Cause.Sequential` and `Cause.Concurrent`. `catch_causes` keeps only the first caught value and accumulates only uncaught branches. If all branches are caught, the whole composite cause becomes a single success value; all other recovered branch values disappear. For `Suppressed`, if the primary is caught, the caught value is discarded and the finalizer is rethrown as a `Finalizer` cause.

That makes `catch` semantically ambiguous for concurrent or sequential causes. Example shape: `Concurrent [Fail e1; Fail e2]` with a handler that recovers both failures becomes one arbitrary recovery value. A typed error handler should not silently choose one recovery from multiple failed branches unless that policy is explicit and documented.

This is a design-level correctness issue because Eta’s `Cause` tree preserves concurrency and suppression structure, but `catch` collapses it in a way that can surprise users relying on typed failures.

---

## C4. P1 — `Duckdb.Database.open_` can raise outside its result API and can leak an opened DB on post-open failure

**Files:** `lib/duckdb/database.ml:7-23`, `lib/duckdb/types.ml:135-141`

`Database.open_` has result type `(t, error) result`, but it performs `invalid_arg` when `threads <= 0` after entering `Types.wrap`. `wrap` catches only `Failure`, not `Invalid_argument`, so invalid configuration escapes as an exception rather than `Error`.

It also opens the raw database before applying the thread PRAGMA. If `raw_exec_script` fails during the PRAGMA step, the temporary connection is disconnected by `Fun.protect`, but the opened database is not explicitly closed before the exception escapes into `wrap`. That leaves cleanup to the custom finalizer rather than deterministic close.

This breaks the connector’s result-returning contract and creates a resource-lifetime hole during configuration.

---

## C5. P1 — DuckDB dynamic loader state is unsynchronized across domains

**File:** `lib/duckdb/duckdb_stubs.c:37-85`, `lib/duckdb/duckdb_stubs.c:149-187`

The DuckDB C stub has one global `static eta_duckdb_api api`, including mutable fields such as `attempted`, `loaded`, `handle`, `error`, and many function pointers. `load_api` checks and mutates these fields without a lock or atomics.

Concurrent first use from multiple domains can race: one domain can set `attempted`, another can return failure immediately, or a domain can observe partially initialized loader state. Since the rest of the stub calls function pointers from this global, this is a domain-safety bug in the FFI boundary.

The same pattern should be checked in the other C stubs (`turso`, `sqlite`, `ladybug`) even if the exact loader structure differs.

---

## C6. P1 — Several DuckDB C operations may block while holding the OCaml runtime lock

**File:** `lib/duckdb/duckdb_stubs.c:238-280`, `lib/duckdb/duckdb_stubs.c:782-800`

The query/execute paths use `caml_enter_blocking_section` around prepare/execute calls, but explicit close/disconnect and appender flush/close do not. `eta_duckdb_close_database`, `eta_duckdb_disconnect`, `eta_duckdb_appender_flush`, and `eta_duckdb_appender_close` call into DuckDB directly while holding the OCaml runtime lock.

Close/flush/disconnect can perform IO or wait on internal database work. Holding the runtime lock here can stall other OCaml domains and undermine the library’s concurrency story. It is especially inconsistent because the same stub correctly releases the runtime lock for `api.open`, `api.prepare`, `api.execute_prepared`, and appender row finalization.

---

## C7. P1 — DuckDB result cleanup is not exception-safe after native result materialization starts

**File:** `lib/duckdb/duckdb_stubs.c:330-360`, `lib/duckdb/duckdb_stubs.c:530-575`

`eta_duckdb_query` executes a prepared statement, then calls `materialize_rows(&result)`, and only afterwards calls `api.destroy_result(&result)`. `materialize_rows` allocates OCaml strings, blocks, tuples, and lists.

If any OCaml allocation raises during materialization, `api.destroy_result` is skipped. The same shape exists wherever native resources are destroyed after OCaml allocation rather than protected by a cleanup path. This can leak DuckDB result memory under allocation failure or unexpected exception from conversion logic.

---

## C8. P1 — SQLite statement finalization is not exception-safe in common query/exec paths

**File:** `lib/sql/sqlite.ml:475-487`, `lib/sql/sqlite.ml:626-648`

`exec_result` prepares a statement, calls `step`, and finalizes only through normal control-flow branches. `query_one_int_result` similarly finalizes after step/drain branches. If `step`, `column_int`, `check`, or another operation raises unexpectedly, the statement is not finalized.

This is a resource leak and can also leave locks held longer than expected in SQLite. Because these functions sit below higher-level migrations and raw execution paths, leaked statements can become visible as “database is locked” failures elsewhere.

---

## C9. P1 — Transaction helpers leave transactions open on commit failure

**Files:** `lib/sql/sqlite.ml:521-535`, `lib/duckdb/connection.ml:72-85`

Both SQLite and DuckDB transaction helpers run `commit` after a successful body and simply return the commit error if it fails. They do not attempt rollback or otherwise mark/repair the connection state after commit failure.

Commit failure is rare, but when it occurs the connection can remain in an unknown transactional state. In a pool, that connection may then be returned to the pool unless a higher layer rejects it. This is a user-impacting lifecycle bug because the next borrower can inherit an open or failed transaction.

---

## C10. P2 — Semaphore over-release is silently clamped, hiding lifecycle bugs

**Files:** `lib/eta/semaphore.ml:72-76`, `lib/eta/semaphore.mli:30-36`

The implementation of `Semaphore.release` does:

```ocaml
t.available <- min t.max_permits (t.available + n)
```

The interface says releasing more permits than capacity is a programmer error, but the behavior clamps instead. Silent clamping hides double-release and release-without-acquire bugs, both of which matter because `Pool.shutdown` explicitly releases `max_size` permits during shutdown and pool logic depends on permit accounting.

This is P2 rather than P1 because it is unlikely to corrupt memory, but it can mask real resource lifecycle errors.

---

## C11. P2 — Pool waiting metrics can report stale cancelled/resolved waiters

**Files:** `lib/eta/semaphore.ml:27-31`, `lib/eta/semaphore.ml:42-62`, `lib/eta/pool.ml:70-80`

`Semaphore.waiting` returns `Queue.length t.waiters`, but cancelled and resolved waiters remain in the queue until `take_ready_waiter` later skips them. Pool stats report `waiting = Semaphore.waiting t.sem`, so observability can overstate live waiters after cancellation or after resolved-but-unclaimed waiters.

This is not a safety bug, but it can mislead operational users diagnosing pool saturation.

---

## C12. P2 — `map_error` documentation overclaims finalizer mapping

**Files:** `lib/eta/effect.mli:357-361`, `lib/eta/cause.ml:379-388`

The public docs say every `Cause.Fail` in the tree is mapped, including failures nested under `Finalizer` or `Suppressed`. The implementation of `Cause.map` maps primary typed failures but leaves `Finalizer cause` and `Suppressed.finalizer` unchanged.

This mismatch matters because cleanup failures are intentionally rendered into `Cause.Finalizer.t`, whose `Fail` payload is a `string`, not the original typed error. The code may be defensible; the documentation is not.

---

## C13. P2 — SQL DSL is type-aware, not a complete SQL validity boundary

**Files:** `lib/sql_dsl/eta_sql_dsl.mli:135-150`, `lib/sql/eta_sql.mli:1-10`, `lib/sql/connection.mli:1-25`, `lib/duckdb/eta_duckdb.mli:93-104`

The SQL DSL interface is honest that scope evidence does not prove `GROUP BY` correctness, cardinality, correlation legality, alias uniqueness, or backend-specific coercion behavior. The SQLite package also explicitly exposes raw SQL escape hatches, and DuckDB exposes raw `query`, `execute`, and `exec_script` alongside typed compiled queries.

So the typed DSL cannot guarantee “all SQL from this package is valid and typed.” It can prevent many table/column/projection mistakes inside the typed builder, but users and connector modules can bypass it easily. That is acceptable if documented as a design boundary, but it should not be marketed as a closed type-sound SQL layer.

---

# 2. Code Quality Review

## Q1. P2 — Several modules are too large to audit locally

The package contains many modules above 500 LOC, including:

| Module                                 | Approx. LOC | Concern                                                                                        |
| -------------------------------------- | ----------: | ---------------------------------------------------------------------------------------------- |
| `lib/sql/sqlite_stubs.c`               |         988 | SQLite FFI, allocation, lifetime, and binding logic are all interleaved.                       |
| `lib/ladybug/ladybug_stubs.c`          |         955 | Large embedded-DB C surface with likely similar audit burden.                                  |
| `lib/sql_dsl/eta_sql_dsl_query.ml`     |         918 | Core DSL types, builders, renderers, and compiled query machinery in one file.                 |
| `lib/stream/eta_stream.ml`             |         817 | Stream algebra, file reading, merge, parallel flat-map, supervision, and queues in one module. |
| `lib/duckdb/duckdb_stubs.c`            |         801 | Dynamic loading, custom blocks, binding, result materialization, appender logic all mixed.     |
| `lib/otel/eta_otel.ml`                 |         744 | OTel spans/logs/metrics/export-ish logic in one place.                                         |
| `lib/ai/eta_ai.mli`                    |         727 | Core types, JSON helpers, SSE, transport, observability, and providers in one interface.       |
| `lib/sql/sqlite.ml`                    |         712 | Connection, statement, backup, transaction, typed/raw execution in one module.                 |
| `lib/schema/eta_schema.ml`             |         680 | Schema combinators, encoders, decoders, and metadata in one module.                            |
| `lib/eta/effect.mli`                   |         646 | Public effect API, blocking, islands, supervision, observability, resources all together.      |
| `lib/sql/migrate.ml`                   |         636 | Migration parsing/planning/execution mixed.                                                    |
| `lib/ai/anthropic/eta_ai_anthropic.ml` |         565 | Encoding, decoding, streaming, auth, prompt cache, and request execution together.             |
| `lib/eta/blocking_runtime.ml`          |         521 | Worker state machine, queueing, cancellation, events, and shutdown all in one module.          |
| `lib/eta/pool.ml`                      |         519 | Pool state, metrics, eviction daemon, acquisition FSM, shutdown, health checks together.       |

The biggest maintainability risk is that correctness-critical lifecycle code is embedded in large modules where local invariants are hard to see. The FFI stubs should be split by native handle lifecycle, binding, stepping/querying, materialization, and dynamic loading. The SQL DSL should separate AST/types, rendering, compiled query decoding, and schema generation.

---

## Q2. P2 — Runtime type erasure is concentrated, but still hard to audit

**Files:** `lib/eta/effect.ml:44-69`, `lib/eta/runtime_core.ml:236-273`, `lib/eta/effect_core.ml:151-158`

`Effect.run` casts the runtime to `Obj.t Runtime_core.t`, while typed failures are recovered through a keyed exception mechanism and rendered through `Obj.repr`/`Obj.obj` paths. The comment explains the intent: one run can cross effects with different typed-failure parameters.

That design can work, but it raises the audit burden. Every place that captures, maps, renders, or rethrows a cause has to preserve the right key and renderer. The `fiberless_frame` issue and `catch` behavior above show how easy it is for this erased core to become fragile.

---

## Q3. P2 — Resource-bracketing patterns are repeated and inconsistent across connectors

**Files:** `lib/duckdb/appender.ml:21-38`, `lib/duckdb/bulk.ml:16-29`, `lib/duckdb/connection.ml:72-85`, `lib/sql/sqlite.ml:521-535`

`Appender.with_appender` and `Bulk.with_appender` duplicate almost identical bracket logic. SQLite and DuckDB transaction helpers also duplicate commit/rollback patterns and share the same commit-failure weakness.

This is not just stylistic duplication. Repeated resource patterns tend to diverge subtly, and here they already do: some cleanup is protected, some errors are ignored, and some commit failure paths do not restore connection state.

---

## Q4. P2 — Raw SQL and typed SQL are mixed at the same abstraction level

**Files:** `lib/sql/eta_sql.mli:1-10`, `lib/sql/connection.mli:13-25`, `lib/duckdb/eta_duckdb.mli:93-104`

The interfaces expose typed compiled operations and raw query/execute operations side by side. The docs do call out the escape hatch, which is good, but the module boundary still makes it easy for application code to bypass the typed layer accidentally.

A cleaner boundary would keep typed execution as the default public surface and move raw execution into explicitly named submodules/packages with stronger wording and narrower visibility.

---

## Q5. P2 — AI provider modules still contain a lot of repetitive endpoint plumbing

**Files:** `lib/ai/openai/chat_completions.ml:1-32`, `lib/ai/openai/responses.ml:1-33`, `lib/ai/openrouter/responses_impl.ml:1-29`, `lib/ai/openai_compat/eta_ai_openai_compat.ml:76-134`

The OpenAI, OpenRouter, and compatible-provider modules share patterns: choose provider, encode request, build HTTP request, run under span, stream variant mutates `stream = true`, decode errors. There is some common code, but endpoint modules still repeat the request/run/stream wrapper shape.

This duplication makes future behavior changes risky. For example, adding consistent transport observability suppression or response-size caps would require checking many wrappers.

---

## Q6. P2 — Public `Effect` interface has too many concerns in one module

**File:** `lib/eta/effect.mli:49-646`

`Effect.mli` includes pure effects, sync, islands, blocking pools, mapping/binding, concurrency, cancellation, retry, resource finalization, background supervision, supervisor DSL, tracing, logging, metrics, source locations, runtime entry, and private hooks.

The API is coherent at the package level, but users reading `Effect` must absorb many independent concepts at once. This also makes documentation drift more likely, as seen with `map_error` and island cancellation text. Splitting the public surface into narrower documented modules while keeping a convenience barrel would make the invariants easier to maintain.

---

## Q7. P2 — Optional OxCaml island design is now part of the core Eta API

**Files:** `lib/eta/effect.mli:58-120`, `lib/eta/effect_island.ml:6-44`, `lib/eta/island_runtime.ml:1-111`

The H3 research note argues for small explicit islands and avoiding a full portable `Effect.t` split, with island concepts limited to portable callback, portable input/output, indexed batch result, and materialized worker failure.  The implementation aligns with that shape, but it is embedded in the core `eta` public `Effect` API rather than isolated as an optional package/track.

That is a design-risk finding, not a request to remove it. If OxCaml portability remains experimental or compiler-specific, embedding it in the central API increases churn for all Eta users.

---

## Q8. P3 — Naming and role boundaries are inconsistent across database packages

**Files:** `lib/sql/connection.mli:13-25`, `lib/duckdb/eta_duckdb.mli:85-115`, `lib/turso/connection.ml` and related modules

SQLite uses `Connection.Typed` and `Connection.Raw`; DuckDB exposes raw and typed methods directly under `Connection`; Turso has its own `compiled_ops` and backend naming. This makes similar operations feel different by backend.

The inconsistency is manageable now, but it will become harder as more backends are added.

---

# 3. AI Slop Review

I did not find much obvious “commented-out unfinished code” slop in the inspected hotspots. The more concerning patterns are over-documentation, wrapper proliferation, and comments that sound confident but are not quite true.

## S1. P2 — Documentation overclaims behavior in places where the implementation is weaker

**Files:** `lib/eta/effect.mli:104-110`, `lib/eta/effect.mli:357-361`, `lib/eta/semaphore.mli:30-36`, `lib/eta/semaphore.ml:72-76`

The island docs claim timeout/cancellation can stop waiting for a batch, while the implementation waits synchronously through `Par.Pool.run_many_on_workers`. The `map_error` docs claim finalizer failures are mapped, while `Cause.map` leaves finalizer payloads unchanged. The semaphore docs call over-release a programmer error, while the implementation clamps.

This is a classic “polished prose ahead of code” smell. The comments are not merely explanatory; they assert semantics users may rely on.

---

## S2. P2 — Many comments restate module organization rather than invariants

**Files:** `lib/eta/effect_blocking.ml:1-2`, `lib/eta/effect_concurrent.ml:1-3`, `lib/eta/effect_resource.ml:1-2`, `lib/ai/openai/eta_ai_openai.ml:1-2`

Several internal modules start with comments like “Internal: see Effect for the public surface” or “public type and value signatures live in .mli.” These are not harmful, but they are low-value comments that can crowd out more important invariants.

For high-risk modules, comments should focus on cancellation, ownership, cleanup ordering, and native-handle lifetime, not restating that the implementation is decomposed.

---

## S3. P2 — Provider modules have many tiny pass-through wrappers

**Files:** `lib/ai/openai/eta_ai_openai.ml:1-55`, `lib/ai/openrouter/eta_ai_openrouter.ml:1-83`, `lib/ai/openai_compat/eta_ai_openai_compat.ml:96-134`

The AI provider packages contain many functions that just select a default provider and delegate to a common runner. Some of this is necessary for a nice public API, but the density of wrappers suggests generated or boilerplate-heavy code that should be reviewed for consistency rather than trusted module-by-module.

The risk is not that a wrapper exists; it is that endpoint-specific behavior can drift while the wrapper code looks mechanically correct.

---

## S4. P2 — Gratuitous “builder” records appear for very small configuration objects

**Files:** `lib/ai/anthropic/eta_ai_anthropic.ml:7-14`, `lib/ai/openrouter/common.ml:8-38`, `lib/ai/openai/realtime.ml:8-39`

Examples include `prompt_cache`, `attribution`, `routing`, and `session` builders. Some are justified, especially `routing` and realtime `session`, but the pattern is widespread: small records plus `unit -> record` constructor plus validation wrapper.

This is not wrong OCaml, but it can become ceremony. The test is whether these builders enforce nontrivial invariants; when they do not, a plain record or simple function would be clearer.

---

## S5. P2 — Handwritten arity ladders and DSL boilerplate deserve generation or sharper containment

**File:** `lib/sql_dsl/eta_sql_dsl_query.ml:1-918`, `lib/sql_dsl/eta_sql_dsl.mli:1-427`

The SQL DSL necessarily has some structural duplication because OCaml lacks variadic generics. Still, a 918-line query module with projections, sources, expressions, rendering, compiled query types, and schema generation is the sort of code where AI-generated or hand-expanded boilerplate can hide one wrong case.

I would not call the duplication itself slop; I would call it a review hazard. The remedy is to isolate the generated/structural parts from the semantic parts so reviewers know where mistakes matter.

---

## S6. P3 — Re-export barrels make the code look simpler than the dependency graph is

**Files:** `lib/eta/effect.ml:1-18`, `lib/duckdb/eta_duckdb.ml:1-42`, `lib/ai/eta_ai.ml:1-82`

The barrels are convenient, but they also flatten very different concerns into one surface: effect interpretation, resources, islands, blocking, supervision, observability, database DSLs, and provider transport. This can create a “looks small at the top” illusion while the real coupling is deep.

This is more maintainability slop than correctness slop, but it matters for a library that wants strong semantic guarantees.

---

## S7. P3 — Defensive boilerplate sometimes obscures the true invariant

**Files:** `lib/ai/openai_codec/core.ml:19-47`, `lib/ai/openrouter/common.ml:44-69`, `lib/ai/openai/transcriptions.ml:14-55`

There are many validation helpers that return `Unsupported` or `Decode_error` for malformed user-side values: non-empty names, finite temperatures, safe multipart header values, routing provider names, and so on. Most are reasonable, but the pattern can become “validate everything everywhere” without a clear boundary between caller validation, provider capability limits, and encoding safety.

This is not a bug, but it is a review smell: defensive wrappers should be tied to a concrete threat model or provider contract.

---

# Highest-priority repair themes

The next repair targets I would prioritize are:

1. **Make island coordinator waits Eio-aware or document them as fully blocking.** This is the clearest mismatch between public semantics and implementation.
2. **Eliminate or domain-localize `fiberless_frame`.** The current global fallback is too risky for OCaml 5.
3. **Audit FFI lifecycle paths with exception-safety and blocking-section checklists.** DuckDB and SQLite already show concrete leaks/blocking inconsistencies.
4. **Revisit composite-cause `catch` semantics.** Either document the “first recovered value wins” policy or change the API so composite recovery cannot discard branch information silently.
5. **Tighten public docs where they overclaim.** `map_error`, semaphore over-release, and island timeout/cancellation are the immediate examples.
