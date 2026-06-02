## 1. Correctness Review

No P0 stood out from the packaged source alone. The highest-risk items are cancellation/resource lifecycle bugs and cross-thread leased-resource hazards.

### [P1] Turso pool can use `Detach_started` blocking pools with leased DB handles

**Files:** `lib/turso/pool.ml:36-44`, `lib/turso/pool.ml:60-99`; compare `lib/sql/pool.ml:33-49`, `lib/duckdb/pool.ml:50-65`.

`lib/turso/pool.ml` accepts `?blocking_pool` and directly forwards it to `Eta.Effect.blocking_result` for `query`, `select`, `returning`, `execute`, `execute_compiled`, and `run_schema` while the DB handle is borrowed from `Eta.Pool.with_resource`. There is no rejection of `Blocking.Pool.Detach_started`. That is dangerous because a started blocking job can detach on cancellation while `Eta.Pool.with_resource` finalizes and returns the same DB handle to the pool. The SQLite and DuckDB pools explicitly reject `Detach_started` for leased connections, which makes this omission look accidental, not an intentional semantic difference.   

### [P1] `Eta.Pool.shutdown ~deadline` can untrack idle resources before close finishes

**Files:** `lib/eta/pool.ml:250-277`, `lib/eta/pool.ml:303-311`, `lib/eta/pool.ml:540-570`.

`begin_shutdown` removes all idle entries from `t.idle` and zeroes `idle_count` before running `close_entries`. `shutdown ~deadline` wraps this drain in `Effect.timeout_as`. If the deadline cancels the close path, those idle resources have already been removed from pool state. Worse, `close_entry` runs `mark_closed` in `Effect.finally`, so a cancelled or interrupted `release_conn` can still decrement `total` and increment `closed`, even though the underlying resource may not actually be closed. This is a resource leak plus incorrect accounting.   

### [P1] User-raised `Exit` is converted into interruption

**Files:** `lib/eta/runtime_core.ml:42-62`; related supervisor cancellation use at `lib/eta/effect_supervisor_scope.ml:66-91`.

`Runtime_core.cause_of_exn` treats the ordinary OCaml `Exit` exception as `Cause.interrupt`. That means user code inside `Effect.sync`, blocking callbacks, or finalizers can accidentally raise `Exit` and have it classified as cancellation rather than a defect. This loses diagnostics and may also be swallowed by paths that intentionally ignore interrupt-only causes. The supervisor code also uses `Exit` as an internal cancellation signal, which makes the ambiguity more likely to leak into user-visible cause classification.  

### [P1] `with_background` can hide background child cleanup failures

**Files:** `lib/eta/effect_supervisor_scope.ml:113-116`, `lib/eta/effect_supervisor_scope.ml:137-166`.

Supervisor children record failures with `Runtime_supervisor.record_failure`, but `supervisor_scoped` only cancels children in a `finally` block and returns the body result; it does not inspect recorded failures unless the user explicitly asks through `Supervisor_failures`/`Supervisor_check`. `with_background` builds directly on this pattern, so a background task that fails during cancellation or cleanup can be recorded and then ignored while the foreground `use` succeeds. That undermines the library’s otherwise careful finalizer-diagnostic semantics.  

### [P2] `tap_error` observes only top-level `Cause.Fail`

**Files:** `lib/eta/effect_core.ml:201-259`, `lib/eta/effect_core.ml:261-277`.

`catch` traverses `Sequential` and `Concurrent` causes, and `map_error` maps through the cause tree. `tap_error`, however, only runs the observer for `Exit.Error (Cause.Fail err)` and silently skips typed failures nested under `Sequential`, `Concurrent`, or `Suppressed.primary`. This makes `tap_error` unreliable for errors produced by `par`, `all`, timeout races, finalizer suppression, and other composed effects. 

### [P2] Semaphore acquisition can barge ahead of queued waiters

**Files:** `lib/eta/semaphore.ml:45-77`, `lib/eta/semaphore.ml:79-106`.

The semaphore wakes queued waiters FIFO from the head, but fresh `try_acquire` and fresh `acquire` both take permits immediately whenever `available >= n`, without checking whether waiters are already queued. A small request can therefore bypass an older larger request. That may be acceptable, but it conflicts with the surrounding pool/channel documentation style that describes ordered wake-one queues and can cause starvation-like behavior for large permit requests.

### [P2] OpenAI multipart transcription builder allows body boundary injection/corruption

**Files:** `lib/ai/openai/transcriptions.ml:20-52`, `lib/ai/openai/transcriptions.ml:54-88`.

The multipart code validates field names, filename, and content type, but field values are appended raw. The boundary is deterministic from the file bytes. A prompt, language, response format, or extra field value containing `\r\n--<boundary>` can corrupt the multipart body or introduce extra parts. Even if provider-side parsing rejects it, this is still an encoding bug at the transport boundary.  

### [P2] DuckDB open/connect C paths lack failure cleanup / blocking consistency

**Files:** `lib/duckdb/duckdb_stubs.c:360-377`, `lib/duckdb/duckdb_stubs.c:394-403`.

`eta_duckdb_open` calls `api.open` in a blocking section but, if `rc != 0`, raises without attempting to close a non-null partial `db` handle. Many C APIs leave output handles null on failure, but this wrapper does not defend against a partially initialized handle. `eta_duckdb_connect` also calls `api.connect` without a blocking section, unlike open/disconnect/query execution. The issue is not necessarily a crash in normal DuckDB behavior, but the FFI boundary is less defensive than the rest of the stub. 

### [P3] SQL DSL type soundness is intentionally narrow and bypassable

**Files:** `lib/sql_dsl/eta_sql_dsl_query.mli:101-116`, `lib/sql_dsl/eta_sql_dsl_query.mli:86-91`.

The DSL itself documents that scope evidence tracks table visibility only; it does not prove `GROUP BY` correctness, cardinality, correlation legality, alias uniqueness, or backend coercion behavior, and callers can bypass it through raw SQL APIs. That is acceptable if positioned as “typed query construction,” but it should not be marketed as preventing invalid SQL generally. The alias API also explicitly does not create an independent phantom scope, which limits self-join expressiveness and can surprise users.  

---

## 2. Code Quality Review

### [P1] Several modules are too large and mix multiple responsibilities

**Files:** `lib/sql_dsl/eta_sql_dsl_query.ml:1-935`, `lib/stream/eta_stream.ml:1-818`, `lib/ladybug/eta_ladybug.ml:1-784`, `lib/otel/eta_otel.ml:1-751`, `lib/ai/eta_ai.mli:1-731`, `lib/sql/sqlite.ml:1-720`, `lib/schema/eta_schema.ml:1-691`, `lib/sql/migrate.ml:1-637`, `lib/eta/effect.mli:1-635`, `lib/eta/pool.ml:1-577`.

The largest modules combine model types, renderers/codecs, lifecycle state machines, error mapping, observability, and public API docs. The worst architectural offenders are `eta_sql_dsl_query.ml`, `eta_stream.ml`, `eta_otel.ml`, `eta_ai.mli`, and `eta/pool.ml`. `Pool` even contains an inline comment explaining why the state machine is deliberately centralized, which is a useful warning but also a sign that the module is carrying too much invariant load. 

### [P2] `Effect.mli` is a kitchen-sink public surface

**Files:** `lib/eta/effect.mli:1-80`, `lib/eta/effect.mli:591-634`.

The interface combines core effect algebra, islands, blocking pools, concurrency, supervision, resources, observability, context propagation, metrics, and private extension hooks. The opening comment says implementation details should stay out of this facade, but the same signature exposes `Private.daemon`, `Private.named_attrs`, and metric batching hooks. That is a leaky public boundary and makes downstream users depend on unstable internals. 

### [P2] Multidomain safety alerts are suppressed in the core library stanza

**Files:** `lib/eta/dune:1-30`.

The `eta` library builds with `-alert -unsafe_multidomain -alert -do_not_spawn_domains`, while the same library includes `par_runtime`, `par_scheduler`, `effect_island`, and `island_runtime`. Suppressing exactly the alerts relevant to multicore/domain safety increases the chance that later unsafe captures or domain-spawning hazards enter unnoticed. This is especially risky in an OxCaml library using portability modes and custom parallel runtime pieces.

### [P2] Connector pools duplicate the same blocking/leased-resource policy

**Files:** `lib/sql/pool.ml:30-49`, `lib/sql/pool.ml:92-120`, `lib/duckdb/pool.ml:47-65`, `lib/turso/pool.ml:36-99`.

SQLite and DuckDB each implement their own `blocking_result`, detach-started rejection, timeout/cancel/interrupt policy, and `Eta.Pool.with_resource` wrapper. Turso implements a similar skeleton but misses the detach-started guard. This is exactly the sort of duplication that creates policy drift. A shared “leased blocking resource” helper would reduce correctness divergence.  

### [P2] Runtime erasure relies on identity casts and `Obj.magic`

**Files:** `lib/eta/runtime_erasure.ml:1-13`.

The comments correctly isolate the representation casts, but the module still uses `%identity` casts and `Obj.magic` to bridge public abstract types to private runtime representations. That is sometimes unavoidable in this design, yet it should be treated as an audited unsafe boundary with tests/invariants around every representation change. Right now the abstraction safety depends on discipline and comments. 

### [P2] `Host_eio` mirrors a large slice of Eio behind custom module types

**Files:** `lib/eta/host_eio.ml:1-70`, `lib/eta/host_eio.mli:1-95`.

`Host_eio` defines proxy module types for Unix, Time, Net, Flow, Switch, Fiber, and Cancel, then stores first-class modules in a record. The utop motivation is real, but this adds a parallel abstraction layer over Eio that many internals must thread through. It increases coupling to Eio’s shape while pretending to abstract it. 

### [P3] Facade modules add many pass-through aliases

**Files:** `lib/ai/openai/eta_ai_openai.ml:1-63`, `lib/ai/openrouter/responses_impl.ml:1-24`, `lib/ai/openrouter/embeddings_impl.ml:1-17`.

The AI provider facades are mostly forwarding: `let responses = Responses.run`, `let speech = Speech_endpoint.run`, small endpoint modules with single `create`/`generate` wrappers, and request modules that only choose a provider and call shared helpers. Some of this is API ergonomics, but it creates extra navigation cost and duplicates module shapes across providers.

### [P3] Pool shutdown drains by polling instead of condition signaling

**Files:** `lib/eta/pool.ml:531-538`.

`wait_until_drained` polls `t.active = 0` every 1 ms. The rest of the library uses promises/conditions for cancellation-safe waiting. Polling is simple, but it creates latency/noise under high churn and is another place where lifecycle state is observed indirectly rather than via an explicit drain condition. 

---

## 3. AI Slop Review

### [P1] Hallucinated/impossible error channel in OpenAI Realtime

**Files:** `lib/ai/openai/realtime.ml:180-214`.

`type realtime_error = [ Eta_http.Ws.Client.ws_error | \`Encode of string ]`, but `client_event_json`always returns`Stdlib.Ok`, and `client_event_to_string` just forwards that impossible error. There is no branch that constructs `` `Encode``. This looks like a generated defensive error channel that was never connected to a real validation path. 

### [P2] Excessively verbose documentation restates simple types and design intent

**Files:** `lib/eta/effect.mli:1-80`, `lib/eta/effect.mli:591-634`, `lib/eta/pool.ml:1-5`.

There is useful documentation here, but many comments explain obvious type roles, defend implementation choices, or restate the API in prose. The `Effect.mli` header and `Private` section are especially dense. This reads like generated “explain everything” prose rather than curated public reference text.  

### [P2] Defensive boilerplate produces misleading success paths

**Files:** `lib/eta/pool.ml:257-277`, `lib/eta/pool.ml:303-311`.

`close_entry` catches close failures into `` `Close_failed`` and then always runs `mark_closed` in `finally`. This is more than style: the defensive “always mark closed” boilerplate can make state accounting lie when close is cancelled or fails. The pattern looks carefully structured, but the state transition is semantically wrong. 

### [P2] Provider endpoint wrappers are over-abstracted

**Files:** `lib/ai/openai/eta_ai_openai.ml:10-63`, `lib/ai/openrouter/responses_impl.ml:6-24`, `lib/ai/openrouter/embeddings_impl.ml:6-17`.

The provider code contains many micro-modules and wrappers whose bodies are “select provider, call shared helper.” That style is common in generated SDKs: lots of symmetry, little domain-specific logic, and many names to learn. It would be easier to maintain if provider families shared fewer facade layers and exposed endpoint helpers directly.

### [P2] Multipart builder has “looks safe” validation but misses the actual risky values

**Files:** `lib/ai/openai/transcriptions.ml:20-52`, `lib/ai/openai/transcriptions.ml:54-88`.

The code validates disposition names, filename, and header values, which gives an impression of complete multipart safety. It then writes field values raw and never checks the generated boundary against body content. This is a classic half-defensive pattern: enough validation to look deliberate, not enough to protect the real serialization invariant. 

### [P3] Comments acknowledge limits instead of simplifying APIs

**Files:** `lib/sql_dsl/eta_sql_dsl_query.mli:101-116`, `lib/eta/effect.mli:49-57`.

The SQL DSL documentation lists several things it does not prove, and the island docs list many things the primitive does not imply. These caveats are honest, but the pattern suggests APIs are broad enough to invite overinterpretation. Where possible, narrower names or separate modules would reduce the need for long “not this, not that” comments. 

### [P3] Repeated `Stdlib.Error _ as error -> error` and forwarding aliases add noise

**Files:** `lib/ai/openai/transcriptions.ml:8-18`, `lib/ai/openai/eta_ai_openai.ml:25-36`.

Several provider modules repeatedly match a parse/decode result only to return the error unchanged, and facade modules define long runs of aliases like `let encode_speech = ...`, `let transcription_request = ...`, `let transcription = ...`. This is not wrong, but it is a strong “generated SDK” smell and makes reviewed code larger than its behavior.

---

## Package completeness note

The package is large enough for a meaningful static review, but it is still a Repomix snapshot: binaries and any ignored/excluded files are outside this pass. The findings above should be validated against the real repository with build, tests, and targeted cancellation/FFI tests before assigning repair ownership.

1. Correctness Review
P0 (Concurrency/Resource Leak): Effect.race permanently leaks the winning value on cancellation
Files: lib/eta/effect_concurrent.ml (lines 92-108), lib/eta/pool.ml (lines 169-180)
Effect.race sets winner := Some value, fails the inner race switch to cancel the losers, and then blocks on fiber_await_cancel frame. If the outer switch is cancelled (e.g., by a timeout) while waiting for the losers to tear down, fiber_await_cancel throws Eio.Cancel.Cancelled. This propagates out of the race, bypassing the return block entirely. The winning value is permanently dropped.
Because Eta.Pool.acquire_permit relies on Effect.race to race Semaphore.acquire against pool shutdown, a cancellation hitting exactly during this teardown window permanently leaks a pool connection permit, eventually causing a pool deadlock.
P0 (Resource Leak): TOCTOU race in HTTP/1.1 connection pool initialization
File: lib/http/client/client.ml (lines 50-59)
make_h1 looks up the origin pool in pools using Hashtbl.find_opt. If it finds None, it yields to execute the effect H1_client.make_pool and then inserts the result into the table via Hashtbl.replace. If two requests to a new origin arrive concurrently, both will see None, both will create a pool (complete with background eviction daemons), and the second will blindly overwrite the first. The first pool and all its connections are permanently orphaned.
P0 (Resource Leak): Eta_duckdb leaks database handles on pool creation failure
File: lib/duckdb/pool.ml (lines 48-52)
Eta_duckdb.Pool.create opens the underlying DuckDB database handle before passing it to Eta.Pool.create. If Eta.Pool.create fails or is cancelled (e.g., while spawning the eviction daemon), the database handle is never closed and leaks permanently. It must be wrapped in Effect.acquire_release.
P1 (Memory/Performance Hazard): DuckDB and Ladybug materialization exhausts memory
Files: lib/duckdb/duckdb_stubs.c (lines 191-209), lib/ladybug/ladybug_stubs.c (lines 352-376)
The C stubs for DuckDB and Ladybug materialize the entire analytical/Arrow result set into an OCaml list list before returning. Worse, they allocate a new OCaml string for the field name for every single cell. Querying an OLAP database for 1M rows with 10 columns will allocate 10M redundant string field names, 10M tuples, and 1M lists, pausing the GC and exhausting memory instantly.
P1 (Performance Hazard): O(N²) SQL row decoding
Files: lib/duckdb/types.ml (lines 36-47), lib/turso/types.ml (lines 42-53), lib/duckdb/dsl_backend.ml, lib/turso/dsl_backend.ml
Because Row.t is defined as a (string * Value.t) list, row_nth_value performs a linear scan to decode a column by index. The typed DSL calls this function for every column in the row, meaning that extracting data from a row with N columns takes O(N²) time.
P2 (Correctness): Turso C stubs expose a SQL truncation vulnerability
File: lib/turso/turso_stubs.c (line 228)
eta_turso_prepare passes -1 as the query length to sqlite3_prepare_v2. If the SQL string contains a NUL byte (\000), the query will be silently truncated at the NUL byte by the C driver. While parameterized queries are safe, if an attacker can inject a NUL byte into a dynamic alias or table name, the query will be truncated, potentially bypassing trailing security clauses.
2. Code Quality Review
P1 (Design Flaw): Row.t abstraction is detrimental to performance
Files: lib/sql/row.ml, lib/duckdb/row.ml, lib/turso/row.ml
Abstracting database rows as an association list ((string * Value.t) list) forces massive allocation and O(N) access. A row should either be a dense array of values, or the C statement handle should be passed directly to the decoding functions (which is what Eta_sql successfully does, but Eta_duckdb and Eta_turso fail to do).
P2 (Maintainability Hazard): Massive duplication across SQL connectors
Files: lib/duckdb/, lib/turso/, lib/sql/
The three database packages duplicate large chunks of code, including identical Types.error shapes, decode_failure definitions, Value.t definitions, and DSL backend bindings. These should be extracted into a shared Eta_sql_core package.
P2 (Correctness/Leaky Abstraction): Obj.magic 0 in Par.Iter.filter
File: lib/eta/par_iter.ml (line 92)
let kept = Array.make n_in (Obj.magic 0 : 'a) is used to bypass initialization of a temporary buffer. While currently isolated within the module, using Obj.magic 0 causes OCaml to allocate a boxed array. If 'a is a float, writing floats into it later creates an incorrectly tagged float array. It avoids crashing only because the array is never exposed to external float-array consumers, but it's a dangerous leaky hack.
P3 (Module Boundaries): Monolithic API modules
Files: lib/ai/eta_ai.mli, lib/ai/types.ml
eta_ai.mli is over 500 LOC and acts as a dumping ground for the entire domain logic of the AI package. Types, capabilities, streams, JSON helpers, and endpoint logic are tangled together. The endpoint definitions (Speech, Transcription, Embedding) should be split into submodules.
P3 (Missing Interfaces): Public exposure of internal mechanics
File: lib/http/h2/informational_filter.mli
The Informational_filter exposes complex internal state transitions. As a specialized HPACK interception boundary, it should have a stricter, abstract .mli that hides feed and take behind higher-level logical frame ingestion rules.
3. AI Slop Review
P3 (Gratuitous Abstraction): Extraneous ALPN state machine
File: lib/http/transport/dispatch.ml
The module defines a custom decision = Use_h1 | Use_h2 type and matching functions just to wrap the underlying Alpn.protocol parsing. It adds a pointless layer of indirection where a simple match alpn would suffice.
P3 (Defensive Boilerplate): SQLite integer constants wrapper
File: lib/sql/sqlite_stubs.c
The C stubs manually implement external functions like eta_sqlite_rc_ok, eta_sqlite_rc_row, and eta_sqlite_rc_done just to return standard integer constants (0, 100, 101). This introduces unnecessary C-to-OCaml boundary boilerplate instead of defining the protocol integers directly in sqlite.ml.
P3 (Redundant Boilerplate): Repetitive Tuple Combinators
File: lib/sql_dsl/eta_sql_dsl_query.ml (lines 173-196)
The Projection module defines t2, t3, t4, t5, t6, t7, t8 by manually nesting and mapping pairs over and over. This is a classic hallmark of unreviewed LLM output generating repetitive boilerplate instead of leveraging OCaml's PPX tools (which the project already uses elsewhere).
P3 (Redundant Variables): Meaningless Type Aliases
File: lib/http/h1/h1_client.ml (lines 11-18)
The file re-declares types using type nonrec request = request = { ... } where it repeats the exact record fields already defined in H1_client_types. This creates noisy, unmaintainable duplication with no structural benefit.
P3 (Verbose "Documentation"): Restating the obvious
File: lib/http/tls/openssl.mli (lines 53-56)
Comments like (* Number of encrypted bytes pending in the write BIO. *) for a function named bio_write_pending are redundant and read like generated descriptions of code rather than human-authored API guidance.
