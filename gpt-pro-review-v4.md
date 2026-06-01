
P0: Cancellation Exceptions Swallowed by the Interpreter
Files: lib/eta/runtime_core.ml (lines 35-36), lib/eta/effect.ml (lines 39-40)
Detail: When an Eio fiber is cancelled, it raises Eio.Cancel.Cancelled. Eta's cause_of_exn blindly catches this exception and converts it into a typed Cause.Interrupt None. When Effect.run handles this exit, it returns Exit.Error (Cause.Interrupt None) to the caller. This permanently swallows the Cancelled exception. Eio relies on Cancelled propagating up the call stack so that switches and parent fibers know the cancellation was cooperatively acknowledged. Swallowing it breaks Eio's structured concurrency, leading to deadlocks, Multiple_exceptions panics, or warnings about fibers ignoring cancellation.
Fix: Effect.run and Runtime.run_exn must detect if the exit cause represents an interruption and re-raise the original Eio.Cancel.Cancelled exception.

P0: Mutex Deadlock/Value Leak during Cancellation Cleanup
Files: lib/eta/channel.ml (lines 204, 228), lib/eta/pubsub.ml (lines 155, 205), lib/eta/queue.ml (lines 63), lib/eta/semaphore.ml (lines 83), lib/eta/pool.ml (lines 265).
Detail: The concurrency primitives use Eio.Promise.await or Eio.Condition.await. If the waiting fiber is cancelled, they catch Eio.Cancel.Cancelled and attempt to clean up their queue entries using with_lock t (fun () -> ...). However, with_lock calls Eio.Mutex.lock. In Eio, Mutex.lock checks the cancellation context and will immediately raise Cancelled again because the fiber is already cancelled. This aborts the cleanup logic entirely, leaving dead waiters in the queue. When the resource eventually becomes available, the dead waiter is dequeued, permanently leaking the resource/value to a dead fiber.
Fix: Wrap the lock acquisition in Eio.Cancel.protect during cancellation cleanup, e.g., Eio.Cancel.protect (fun () -> with_lock t (fun () -> ...)). (Note: Blocking_runtime does this correctly via its mutex_use_rw helper).

P1: Left Join in SQL DSL Ignores Nullability
Files: lib/sql_dsl/eta_sql_dsl_query.ml (lines 280-283)
Detail: When performing a LEFT JOIN (via Source.left_join), the columns of the right-hand table become visibly accessible in the expanded scope. However, Scope.left blindly coerces the columns without altering their 'a typ to reflect that they can now be NULL. If a user selects a non-nullable column (e.g., int) from the right side of a left join, the type system expects an int. At runtime, if the row has no match, the database returns NULL. The decoder will encounter Value.Null, fail to parse it, and raise a Decode_error exception, crashing the query.

P2: Custom Block Interior Pointers in DuckDB C Stubs
Files: lib/duckdb/duckdb_stubs.c (lines 255-257)
Detail: duckdb_query creates an OCaml custom block (result_owner_alloc()), extracts an interior C pointer to its payload, and passes that pointer to api.execute_prepared across a caml_enter_blocking_section. While OCaml 5's GC does not currently move custom blocks, relying on interior pointers into the OCaml heap during blocking sections violates the C API safety contract and creates a severe hazard if GC compaction behavior changes. (Note: ladybug_stubs.c avoids this by correctly allocating the result struct on the C stack).

2. Code Quality Review
P2: Memory Churn and Overhead in HTTP/2 Informational Filter
Files: lib/http/h2/informational_filter.ml
Detail: To strip 1xx interim responses before passing frames to ocaml-h2, this filter parses incoming HPACK HEADERS frames using Angstrom, discards them if they are informational, and then re-serializes final headers using Faraday back into wire frames. This imposes massive CPU and allocation overhead on the hot path for every HTTP/2 response. It would be significantly more maintainable and performant to patch or fork ocaml-h2 to drop 1xx responses natively.

P2: Hand-written Arity Limits in Schema Combinators
Files: lib/schema/eta_schema.ml (lines 354-406)
Detail: The record schema builders (record1 through record6) manually duplicate the entire JSON object decoding and encoding logic for each arity. This restricts users to records of at most 6 fields, forcing awkward nesting for larger payloads. This should be replaced with an extensible HList or Applicative Functor pattern to support arbitrary-length records without code duplication.

P3: Tangled HTTP/2 Connection and Multiplexer Boundaries
Files: lib/http/h2/connection.ml, lib/http/h2/multiplexer.ml
Detail: The responsibilities between Connection and Multiplexer are deeply tangled. Multiplexer manages Stream_state and body readers, but Connection owns the socket flow. Multiplexer exposes an awkward read_client_once helper which Connection calls in its read loop, while leaking H2.Client_connection.t back and forth. This makes reasoning about the HTTP/2 state machine lifecycle highly convoluted.

P3: Missing Interface Files
Files: lib/stream/eta_stream_file.ml
Detail: While many internal Effect modules omit .mli files by design (relying on effect.mli), eta_stream_file.ml defines public types (like file_error_kind and operation) exposed in eta_stream.mli. It lacks a dedicated interface file, exposing its implementation details to the rest of the package.

3. AI Slop Review
The codebase is remarkably idiomatic, heavily optimized, and correctly leverages advanced OCaml 5 features (like Eio, lock-free work-stealing, and zero-allocation probes). However, a few AI-typical patterns slipped through:

Gratuitous Abstraction: GADT-based Supervisor AST
Files: lib/eta/effect_supervisor_scope.ml
Detail: The module implements an entire GADT AST (supervisor_scope) and a custom interpreter just to enforce the rank-2 lifetime of supervisor child handles. Constructing and heap-allocating an AST node for every bind, yield, and start operation replicates the effect system inside the effect system. A simpler phantom-type approach or standard capability-passing closure (like Eio.Switch.run) would achieve the exact same compile-time safety without the massive allocation tax.

Defensive Boilerplate in Synchronous Folds
Files: lib/http/client/client.ml (lines 53-70)
Detail: The stats_impl function wraps a simple List.fold_left over a hashtable inside an Eta.Effect.sync block. Since extracting length/capacity counters from memory does not perform any side-effects, I/O, or risk raising synchronous exceptions, lifting it into the effect system is purely defensive boilerplate that adds closure allocation for no benefit.

Redundant "Documentation" Prose
Files: lib/sql_dsl/eta_sql_dsl.mli (lines 169-204)
Detail: The projection combinators (t3, t4, t5, etc.) are accompanied by comments like (* Combine three projections into a tuple. *) and (* Combine four projections into a tuple. *). This is AI-generated filler that literally just restates the type signature in English without adding semantic value.

P0 — Eta.Par has cross-domain data races in the scheduler/job protocol

Files: lib/eta/par_scheduler.ml:39-45, 109-121, 243-283; lib/eta/par_runtime.ml:220-259, 262-289.

Par_scheduler.job stores state, handler, queue links, and exec as ordinary mutable fields. Promotion changes first.state <- Executing and first.exec <- Some ...; wait_for_job can later write j.state <- Reclaimed after releasing pool.mutex. Meanwhile join_slow and join_unit_slow read job.state without holding the scheduler mutex after running branch b. The same job record is therefore shared across domains with non-atomic reads/writes.

Impact: this can manifest as stale reads, double execution of the left branch, missed promoted results, or invariant failures such as “owner observed a reclaimed job.” In OCaml 5/OxCaml, mutable fields shared across domains need a clear synchronization story; this code currently mixes mutex-protected scheduler mutations with unsynchronized owner-side reads.


P1 — Par.Pool.run_many_on_workers scales scheduler state with job count, not worker count

File: lib/eta/par_runtime.ml:134-180.

For a batch of n jobs, run_many_on_workers allocates n synthetic owner workers, registers all of them into the shared scheduler, and assigns one shared_job to each. That means scheduler registry size, stealing scans, and registration/unregistration work become proportional to the batch size.

Impact: large island batches can create huge scheduler metadata and make stealing/heartbeat behavior pathologically expensive. This is especially risky because Effect.Island.map is documented as the batch CPU offload path.

P1 — acquire_use_release is not a lexical bracket and can retain resources longer than callers expect

Files: lib/eta/effect_resource.ml:33-50; lib/eta/effect.mli:404-414.

acquire_use_release is implemented as:

acquire_release ~acquire ~release |> bind body

acquire_release only registers a finalizer in the current frame; it does not open a local scoped boundary around body. The .mli does say the release is tied to the “current runtime boundary or scope,” but the function name and CPS shape strongly imply bracket semantics.

Impact: code such as repeated acquire_use_release calls inside one long-lived effect can accumulate connections/files/resources until the outer runtime or surrounding scope exits. This is a resource-exhaustion bug waiting to happen.

P1 — Domain-isolated blocking pool bypasses OxCaml portability safety

Files: lib/eta/blocking_runtime.ml:315-336; public surface in lib/eta/effect.mli:210-242.

Domain_isolated deliberately uses Domain.spawn with [@alert "-unsafe_multidomain"] and the comment states that Domain.Safe.spawn is not used because the public Blocking API does not enforce portable callbacks.

Impact: this creates a public path for arbitrary closures to run in fresh domains while capturing Eio handles, Eta runtime state, mutable references, database handles, or other nonportable values. The documentation warns users, but the type system does not enforce the boundary. In an OxCaml codebase whose value proposition is portability checking, this is a significant correctness/design hole.

P1 — C finalizers perform potentially blocking database close/finalize work without blocking sections

Files: lib/sql/sqlite_stubs.c:21-36, 206-220, 306-318; lib/duckdb/duckdb_stubs.c:93-124, 301-313, 861-876; lib/turso/turso_stubs.c:73-88, 230-241, 264-276.

The explicit SQLite close/finalize functions enter a blocking section, but the custom block finalizers call sqlite3_close_v2 and sqlite3_finalize directly. The same pattern exists in DuckDB and Turso finalizers.

Impact: finalizers run in GC-sensitive contexts and should not do potentially blocking database work while holding the OCaml runtime lock. This can pause unrelated fibers/domains unpredictably, and finalizer ordering is already weak for DB handles.

P1 — DuckDB database lifetime is not tied to live connections

Files: lib/duckdb/database.ml:48-54; lib/duckdb/connection.ml:8-25; lib/duckdb/types.ml:64-78.

Database.close closes the raw database and sets db.closed <- true without tracking or closing live connection values. Existing connections then observe conn.database.closed and refuse operations, but their raw connection custom blocks still exist and may later be finalized/disconnected after the database has been closed.

Impact: this relies on DuckDB tolerating close-before-disconnect or later finalizer cleanup ordering. At minimum, the OCaml layer allows a resource graph state that the C API normally expects users to avoid.

P2 — SQL DSL type soundness is intentionally partial, and raw bypasses are public

Files: lib/sql/eta_sql.mli:7-10; lib/sql/pool.mli:70-106; lib/sql_dsl/eta_sql_dsl.mli:137-150, 296-325, 328-345.

The package is honest that the typed DSL is not a closed enforcement boundary: Pool.Raw exposes raw SQL; the expression docs explicitly exclude proof of GROUP BY correctness, cardinality, correlation legality, alias uniqueness, backend coercions, and raw execution.

Impact: the typed DSL can prevent many table/column/projection mixups, but it cannot be treated as “typed SQL is always valid SQL.” Left joins also do not automatically make right-side columns nullable at the type level, which is a common SQL soundness trap.

P2 — AI JSON integer decoding silently truncates floats

File: lib/ai/json.ml:42-47.

Json.int_member accepts a JSON float and returns Some (int_of_float value). That silently truncates non-integral provider values instead of rejecting malformed integer fields.

Impact: usage counters, token counts, timestamps, or indexes can be decoded incorrectly if a provider sends 1.5, 1e20, or another non-integer numeric value. This should be a decode error, not a lossy conversion.

P2 — SSE stream buffering is quadratic under fragmented input

File: lib/ai/sse.ml:119-142.

feed_sse appends chunks with stream.buffer <- stream.buffer ^ chunk and repeatedly slices strings with String.sub. The buffer is capped, but the work is still quadratic in the number of chunks before a separator.

Impact: an adversarial or merely highly fragmented SSE response can waste CPU and allocation within the configured cap. This is not a memory-safety issue, but it is a backpressure/performance hazard in streaming paths.

2. Code Quality Review
P2 — Several modules are far beyond the stated maintainability threshold

Large modules make review and invariants difficult. The most concerning ones in this package are:

File	Approx. LOC	Concern
lib/sql/sqlite_stubs.c	988	FFI ownership, blocking sections, DB/stmt lifecycle all in one file
lib/ladybug/ladybug_stubs.c	966	Large generated/embedded DB stub surface
lib/sql_dsl/eta_sql_dsl_query.ml	918	Query AST, rendering, schema, inserts, updates, deletes, projections mixed together
lib/duckdb/duckdb_stubs.c	878	Dynamic symbol loading, handles, result materialization, prepared statements, appender in one file
lib/stream/eta_stream.ml	817	Stream construction, transformation, scope/drain behavior in one module
lib/otel/eta_otel.ml	750	Traces/logs/metrics/export encoding and transport in one module
lib/ai/eta_ai.mli	727	Public provider vocabulary, transport, stream, observability signatures all together
lib/sql/sqlite.ml	719	Raw SQLite wrapper plus config, transaction, row/materialization helpers
lib/schema/eta_schema.ml	680	Schema combinators and encoders in one file
lib/eta/effect.mli	648	Core effect API, islands, blocking, concurrency, resources, observability, supervisors

These should be split around invariants: e.g. SQL expressions vs DDL vs compiled statements; SQLite handle/statement wrappers vs execution helpers; OTel model encoding vs exporter transport; Effect core vs resource/supervisor/observability public signatures.

P2 — Public library modules leak internals because private_modules is missing

Files: lib/ai/openai_codec/dune:1-5; lib/otel/dune:1-5; lib/ppx/dune:1-5.

eta_ai_openai_codec has an .mli for the intended aggregate module, but its Dune stanza does not mark chat, content, core, embeddings, error_codec, responses, stream, or tools as private. eta_otel similarly exposes metric_aggregation and otlp_json unless Dune wrapping/visibility is otherwise constrained.

Impact: internal module names and helper functions become de facto API. That makes future refactors harder and increases accidental dependency risk.

P2 — Effect.Private is a public unstable escape hatch with meaningful behavior

Files: lib/eta/effect.ml:84-104; lib/eta/effect.mli:578-624.

Effect.Private exposes daemon, named_attrs, and metric batching hooks. These are explicitly “unstable,” but they are in the public interface and are used by sibling packages such as Pool.

Impact: internal runtime hooks become part of the package’s coupling surface. External callers can depend on daemon semantics that bypass typed results and report failures through runtime logging, which is hard to unwind later.

P2 — The core effect runtime relies on Obj.magic/Obj.t typed-failure erasure

Files: lib/eta/effect.ml:42-65; lib/eta/runtime_core.ml:21-37, 267-287.

The code intentionally erases the runtime failure type with Obj.magic and stores typed causes inside an Obj.t exception keyed by an integer fail key. The comments explain why, and the keying discipline is coherent, but this is still a fragile central invariant.

Impact: any future change to key generation, renderer scope, or cross-runtime exception propagation can become unsound quickly. This deserves very small, heavily tested modules rather than being spread across effect.ml, effect_core.ml, runtime_core.ml, and instrumentation code.

P2 — Provider packages repeat the same request/run/default-provider plumbing

Files: lib/ai/openai/common.ml, lib/ai/openai/eta_ai_openai.ml, lib/ai/openrouter/common.ml, lib/ai/openrouter/eta_ai_openrouter.ml, lib/ai/openai_compat/eta_ai_openai_compat.ml, lib/ai/anthropic/eta_ai_anthropic.ml.

OpenAI, OpenRouter, OpenAI-compatible, and Anthropic repeat the same pattern: pick provider, encode, create raw request, wrap with span, run request/stream. The top-level modules are mostly aliases and tiny wrappers.

Impact: fixes to streaming, request construction, observability suppression, and error wrapping have to be copied across packages. The duplication is not just stylistic; it increases provider inconsistency risk.

P2 — SQL DSL projections and schema builders are arity-boilerplate heavy

Files: lib/sql_dsl/eta_sql_dsl.mli:217-294; lib/sql_dsl/eta_sql_dsl_query.ml projection section.

The DSL exposes t2 through t8 tuple projections and many duplicated aggregate/projection variants. Some arity boilerplate is normal in OCaml without variadic generics, but the current module mixes all of it with rendering and decoding.

Impact: future projection changes will be repetitive and easy to apply inconsistently. A smaller internal representation plus generated or isolated arity modules would be easier to review.

P2 — Eta.Pool combines too many responsibilities

File: lib/eta/pool.ml:1-517.

Pool handles semaphore admission, idle/active accounting, health checks, resource close failure handling, metrics, logs, eviction daemon, shutdown deadlines, and scoped resource release.

Impact: the resource-lifecycle invariants are hard to audit because they are interleaved with observability and eviction mechanics. This is exactly the kind of module where small state-machine splits pay off.

P3 — Inconsistent lifecycle names make APIs harder to reason about

Examples: Database.open_, open_memory, Connection.connect, Connection.close, Pool.shutdown, Appender.with_appender, acquire_use_release, scoped, with_resource.

Impact: the difference between “close now,” “register for enclosing scope,” “shutdown and drain,” and “discard/interrupt” is not visually obvious. The acquire_use_release finding above is the user-impacting version of this naming problem.

3. AI Slop Review
P2 — Public docs contain an internal “A2 found” breadcrumb

File: lib/ai/eta_ai.mli:507-515.

The public stream documentation says: “A2 found that eta-stream still needs an owned effect-reader source…” This reads like an internal agent/review note accidentally promoted into API documentation.

Impact: it weakens trust in the public interface and suggests the docs were not cleaned for release. Public docs should state the invariant directly, without provenance from an internal reviewer/model.

P2 — PPX still contains an “environment/capability binding” mini-language that does not match the library’s stated effect model

Files: lib/ppx/ppx_eta.ml:21-103; contrast with lib/eta/effect.mli:1-12.

The core Effect docs say dependencies are ordinary OCaml values and Eta does not own a ZIO-style environment. But the PPX parses “capability bindings,” scans the body for direct env usage, and emits an error saying “eta leaf body must use listed captures, not env directly.”

Impact: this looks like leftover design scaffolding from an environment-based effect system. It is plausible-looking, but conceptually inconsistent with the current library model.

P2 — The OpenAI/OpenRouter provider facades are mostly alias layers

Files: lib/ai/openai/eta_ai_openai.ml:1-45; lib/ai/openrouter/eta_ai_openrouter.ml:1-70.

The public modules repeatedly define aliases such as let responses_request = Responses.request, tiny modules whose only function calls a same-named function, and endpoint modules that mostly forward to implementation modules.

Impact: some façade code is useful for API shape, but this amount of forwarding has the “generated barrel file” feel and makes it harder to tell where real behavior lives.

P3 — Excessive defensive prose sometimes restates implementation rather than explaining decisions

Examples include the “barrel” comment in lib/eta/effect.ml:1-4, the long public comments around islands/blocking/resources in lib/eta/effect.mli, and repeated provider module preambles saying signatures live in the .mli.

Impact: the comments are not wrong, but many are self-referential or restate the module organization. The best docs here are the ones that state non-obvious semantics, such as non-preemptive island cancellation; the rest adds noise.

P3 — Generated-looking tuple/projection and wrapper boilerplate should be isolated

Files: lib/sql_dsl/eta_sql_dsl.mli:217-294; lib/ai/openai/eta_ai_openai.ml:1-45.

The repeated t2…t8 projection surface and endpoint wrappers are understandable in OCaml, but keeping them inline with hand-written logic makes the code look mechanically produced and harder to review.

Impact: reviewers must scan repetitive code to find actual semantic differences. Isolating generated/boilerplate sections would make real logic stand out.

P3 — Some validation code is manually nested and repetitive rather than factored

Examples: multipart validation in lib/ai/openai/transcriptions.ml, routing validation in lib/ai/openrouter/common.ml, tool/schema JSON validation across provider codecs.

Impact: this is not a correctness issue by itself, but the style resembles unreviewed generated code: many small local validators, repeated match Stdlib.Error _ as error -> error, and provider-specific strings scattered through functions.
