## 1. Correctness Review

### P0 — `Channel` can overfill/overwrite its ring buffer after receiver cancellation

**Files:** `lib/eta/channel.ml:L85-L88`, `L137-L151`, `L212-L221`, `L245-L255`, `L322-L339`

The bounded channel direct-delivers to a waiting receiver without reserving a buffer slot. A delivered receiver remains in state `Delivered value` until the waiting fiber wakes and calls `claim_receiver`. If that fiber is cancelled first, `cancel_receiver` calls `return_unclaimed_value`, which either hands the value to another waiter or calls `push_front`. `push_front` unconditionally writes into the ring and increments `depth`; it does not check capacity.

A concrete failure with capacity 1:

1. receiver R waits;
2. sender S1 direct-delivers `v1` to R;
3. before R claims, sender S2 sees `depth = 0` and buffers `v2`;
4. R is cancelled;
5. `return_unclaimed_value` calls `push_front v1`, overwriting/overfilling the buffer.

This can violate `depth <= capacity`, lose data, and break FIFO semantics. The relevant implementation shows direct delivery, unclaimed-value return, and unconditional `push_front`.   

---

### P1 — `Pool` can leak capacity/accounting when close/release dies

**Files:** `lib/eta/pool.ml:L224-L248`, `L250-L291`, `L479-L494`

`close_entry` runs `t.release_conn entry.conn`, catches typed failures into `Close_failed`, and only then calls `mark_closed`, which decrements `total` and optionally releases a semaphore permit. If `release_conn` dies with an unchecked defect, interruption, or other non-typed cause, the bind after `close_once` is skipped and `mark_closed` never runs. `release_entry` wraps the close path in `finally (mark_active_close_finished t)`, but that only decrements `active`; it does not decrement `total` or release the resource permit. The result is a permanently shrunken pool.

Shutdown has a related issue: `begin_shutdown` drains idle entries via `close_entries`, implemented as `Effect.concat`. A close failure can stop later idle closes, while shutdown continues to depend on accounting consistency.   

---

### P1 — SQLite C stubs expose close/finalize/step races across blocking sections

**Files:** `lib/sql/sqlite_stubs.c:L206-L219`, `L306-L318`, `L481-L492`; `lib/sql/sqlite.ml:L1-L7`, `L221-L224`

`sqlite3_close_v2`, `sqlite3_finalize`, and `sqlite3_step` are all called after `caml_enter_blocking_section`, but the OCaml wrapper has no per-handle mutex or linear ownership guard. `stmt` is just `{ db; raw }`, and `step stmt` forwards directly to the raw statement. If the same DB/statement is shared across fibers or systhreads, one fiber can finalize or close while another is stepping.

This is especially risky because releasing the OCaml runtime lock makes such interleavings possible even within one Eta program. SQLite has threading modes, but finalizing the exact statement handle concurrently with stepping it is not a safe API contract to expose without a close fence.  

---

### P1 — OpenAI transcription multipart builder validates filename only, not field names or content type

**File:** `lib/ai/openai/transcriptions.ml:L20-L65`

`safe_disposition_value` rejects CR/LF/quotes, but it is applied only to `request.file.filename`. `add_field` interpolates `name` directly into `Content-Disposition`, and `multipart_body` applies it to all `request.extra_fields` names without validation. `request.file.content_type` is also written directly into a `Content-Type:` header. This allows malformed multipart bodies and, if these values are derived from untrusted input, request-header/body injection within the multipart envelope. 

---

### P1 — `Effect.catch` can swallow suppressed finalizer failures

**Files:** `lib/eta/effect_core.ml:L199-L240`; `lib/eta/effect_resource.ml:L20-L43`

`finally` and `acquire_release` preserve cleanup failures as direct failures or `Cause.Suppressed { primary; finalizer }`. However, `catch_cause` recursively handles `Suppressed`, and if both the primary and finalizer typed failures are caught, it returns `Caught value`. That means a cleanup/finalizer failure can disappear completely if the same `catch` handler happens to handle it.

This is surprising for a resource system: a finalizer failure is diagnostic and operationally important, not just another application error to be converted into a success value. At minimum, this needs an explicit “catch typed failures inside finalizers too” contract; as written, it risks making failed cleanup invisible.  

---

### P2 — SQL DSL soundness is explicitly partial and raw APIs bypass it

**Files:** `lib/sql_dsl/eta_sql_dsl.mli:L104-L119`; `lib/sql/connection.mli:L1-L24`; `lib/sql/eta_sql.mli:L1-L12`

The SQL DSL does provide typed table/column/projection structure, but its own interface says scope evidence does not prove `GROUP BY` correctness, cardinality, correlation legality, alias uniqueness, or backend-specific coercions. The SQLite connection interface also exposes `Raw.query`, `Raw.execute`, `Raw.execute_script`, and migration preparation over raw strings. The public `eta_sql.mli` says the DSL is not a closed enforcement boundary and that `Pool.Raw` exposes raw SQL escape hatches.   

This is not necessarily wrong, but it means “typed SQL DSL” should be described as a builder with guardrails, not as a sound SQL type system. User code can still construct invalid SQL through public APIs.

---

### P2 — Island failures are inconsistently materialized

**Files:** `lib/eta/effect_island.ml:L6-L10`, `L28-L45`; `lib/eta/island_runtime.ml:L37-L43`, `L62-L111`; `lib/eta/effect.mli:L70-L110`

The island API documents that worker crashes are materialized for batch APIs and that running callbacks are not preempted. That is honest. But several non-worker island failures are still surfaced as defects: missing island pool configuration comes from `Runtime_core.island_pool` as `failwith`, a stopped pool raises `Invalid_argument`, and `submit`/`submit_map` turn `Worker_died` into `failwith` instead of a typed effect failure. `all_settled` is the only path that returns `Worker_died` values. 

This makes island error behavior depend on which helper is used. For a runtime primitive, configuration errors and worker deaths should have a more consistent failure shape.

---

## 2. Code Quality Review

### P2 — Several modules are too large to audit safely

**Files over ~500 LOC:**

* `lib/sql/sqlite_stubs.c` — 988 LOC
* `lib/ladybug/ladybug_stubs.c` — 955 LOC
* `lib/sql_dsl/eta_sql_dsl_query.ml` — 920 LOC
* `lib/stream/eta_stream.ml` — 817 LOC
* `lib/duckdb/duckdb_stubs.c` — 800 LOC
* `lib/ladybug/eta_ladybug.ml` — 781 LOC
* `lib/otel/eta_otel.ml` — 756 LOC
* `lib/ai/eta_ai.mli` — 727 LOC
* `lib/schema/eta_schema.ml` — 680 LOC
* `lib/sql/sqlite.ml` — 639 LOC
* `lib/eta/effect.mli` — 637 LOC
* `lib/sql/migrate.ml` — 636 LOC
* `lib/ai/anthropic/eta_ai_anthropic.ml` — 565 LOC
* `lib/eta/blocking_runtime.ml` — 521 LOC
* `lib/eta/pool.ml` — 514 LOC

The oversized modules cluster exactly where correctness matters most: FFI, SQL DSL rendering, streams, runtime primitives, migrations, and provider codecs. These should be split around invariants: C handle lifetime, parameter binding, row decoding, SQL AST/rendering, stream state machines, retry/transaction state, and observability export encoding.

---

### P2 — `Effect` is a barrel module plus a large semantic surface

**Files:** `lib/eta/effect.ml:L1-L17`; `lib/eta/effect.mli:L1-L637`

`effect.ml` includes core, resource, concurrent, observability, supervisor, island, and blocking modules into one public surface. `effect.mli` then documents the whole runtime algebra, structured concurrency, observability, blocking, islands, supervisor scopes, and private extension hooks in one 637-line interface. 

This makes it difficult to reason about which sublanguage a function belongs to. It also hides the architectural boundary between “effect description,” “runtime execution,” “fiber concurrency,” “domain offload,” and “observer hooks.” The decomposition exists internally, but the public surface merges the concepts again.

---

### P2 — `Effect.Private` is a leaky integration boundary

**Files:** `lib/eta/effect.ml:L76-L84`; `lib/eta/effect.mli:L594-L637`

`Effect.Private` exposes daemon spawning, named attribute wrapping, and batched metric updates. The `.mli` warns that this is an unstable extension hook, but sibling packages can still couple to these internals. The hooks bypass normal public semantics: `daemon` explicitly runs on the runtime’s outer switch and reports failures outside the typed result channel. 

The design may be necessary, but it is a sign that the public API is missing one or more principled extension points for runtime-owned background work and observability batching.

---

### P2 — Eio host indirection is heavily duplicated through the core interpreter

**Files:** `lib/eta/host_eio.ml:L1-L67`; `lib/eta/effect_core.ml:L42-L130`

`Host_eio` re-declares module types for Unix, Time, Net, Flow, Switch, Fiber, and Cancel. `Effect_core` then branches on `frame.runtime.host_eio` for `with_frame`, switch operations, fibers, cancellation, and yielding. This adapter appears to exist for toplevel-sensitive integrations, but it injects host-selection logic into the hottest and most delicate interpreter paths. It also increases the risk that the host and non-host paths drift semantically. 

A smaller boundary around runtime creation or a single host operations record would be easier to test than repeated `match host_eio` branches throughout `Effect_core`.

---

### P2 — Concurrency primitives duplicate hand-written waiter/cancellation protocols

**Files:** `lib/eta/channel.ml:L1-L375`; `lib/eta/semaphore.ml:L1-L120`; `lib/eta/queue.ml:L1-L120`; `lib/eta/pubsub.ml` waiter sections

`Channel`, `Semaphore`, `Queue`, and `Pubsub` all implement their own waiter states, queue pruning, cancellation counters, resolver ownership, and close semantics. The `Channel` P0 above is exactly the kind of bug this invites. `Semaphore` has a similar “resolved but unclaimed” concept, while `Queue` uses condition variables, and `Pubsub` has active receiver records.  

The primitives are different enough to need custom logic, but there should be shared patterns or invariant tests around “delivered but unclaimed,” “cancelled before claim,” “close while waiters exist,” and “returning permits/values.”

---

### P2 — SQL typed/raw boundary is documented but architecturally blurry

**Files:** `lib/sql/eta_sql.mli:L1-L12`; `lib/sql/connection.mli:L1-L24`; `lib/duckdb/connection.ml:L23-L81`

The package simultaneously presents a typed SQL builder and raw execution surfaces. The docs are honest that raw APIs bypass the typed DSL, but the same public package still makes raw query and script execution readily available. DuckDB’s public connection module also exposes raw `query`, `execute`, and `exec_script` next to typed `select` and `execute_compiled`.   

For users, this blurs whether Eta SQL is intended as a safe typed layer or a convenience wrapper with typed helpers. That distinction matters for API naming, examples, migrations, and soundness claims.

---

### P3 — Provider endpoint wrappers repeat request/run/stream boilerplate

**Files:** `lib/ai/openai/chat_completions.ml`, `lib/ai/openai/responses.ml`, `lib/ai/openrouter/responses_impl.ml`, `lib/ai/openrouter/embeddings_impl.ml`, `lib/ai/openai/speech.ml`

The AI packages already have useful shared codecs and `Common` modules, but many endpoint modules still repeat the same pattern: choose provider, encode request, build HTTP request, run raw/decoded, run stream, or run binary. This is not a correctness bug, but it creates more places for inconsistent span wrapping, streaming flags, max-byte limits, and provider override behavior. 

---

## 3. AI Slop Review

### P2 — Generated-looking unused/no-op code remains in production paths

**File:** `lib/eta/effect_island.ml:L40-L44`

`Island.all_settled` binds `let _ = name` even though `name` is already used in `make ~names:[ name ]`. This is a classic “silence warning / preserve parameter” artifact that should not survive cleanup in a core runtime module. 

---

### P2 — Inconsistent indentation suggests mechanically pasted or weakly reviewed code

**Files:** `lib/duckdb/database.ml:L5-L30`; `lib/duckdb/pool.ml:L6-L20`

`database.ml` indents top-level definitions under `type t = database`, and `pool.ml` starts its main type and function definitions with extra leading indentation. This is minor syntactically, but it is a strong signal that the file was pasted or generated and not normalized by a reviewer/formatter. The same area contains FFI-backed resource lifecycle code, where review discipline matters. 

---

### P2 — “Documentation” sometimes restates aspirations rather than enforcing invariants

**Files:** `lib/eta/effect.mli:L70-L110`, `L247-L265`; `lib/sql_dsl/eta_sql_dsl.mli:L104-L119`; `lib/sql/eta_sql.mli:L1-L12`

The docs often carefully explain limitations: islands do not imply cancellation/preemption; blocking callbacks must not call Eio or run Eta runtimes; SQL typing is not a full soundness boundary. Those statements are useful, but in several cases the code does not enforce the restriction beyond comments and type hints. For example, `blocking` accepts any `unit -> 'a`, so the “must not call Eio operations, run Eta runtimes, submit nested blocking jobs” contract is mostly runtime discipline. The SQL package warns that raw escape hatches bypass typed SQL, but still exposes them.   

This is not “bad documentation”; it is an AI-slop pattern where prose compensates for an API boundary that is not actually tight.

---

### P2 — Gratuitous re-export/alias layers obscure module ownership

**Files:** `lib/sql/eta_sql.ml:L1-L47`; `lib/duckdb/eta_duckdb.ml:L1-L58`; `lib/ai/openai/eta_ai_openai.ml:L1-L49`; `lib/ai/openrouter/eta_ai_openrouter.ml:L1-L75`

Several public modules are mostly barrels: they alias types, re-export submodules, include backend DSLs, and rename endpoint helpers. Some of this is normal OCaml packaging, but the density here makes it hard to see which module owns behavior. In `eta_sql.ml`, comments like “Runtime modules,” “DSL modules,” and “Execution surfaces” are essentially a table of contents over aliases. 

The pattern feels generated because it creates many public names without much local logic, increasing API surface and documentation burden.

---

### P3 — Defensive impossible branches and assertions are scattered through public primitives

**Files:** `lib/eta/channel.ml:L306-L320`; `lib/eta/queue.ml` receive path; `lib/eta/runtime_observability.ml` cause rendering paths

`Channel.send` handles `` `Full`` with `assert false`, and `Channel.recv` handles `` `Empty`` with `assert false`. The queue receive wrapper has the same shape. These branches may be unreachable by construction, but the style makes the invariant implicit and brittle. In a library centered on typed failures and structured causes, `assert false` in public primitives reads like unfinished defensive boilerplate rather than a maintained invariant.  

---

### P3 — Repeated “internal; see Effect for public surface” headers are boilerplate noise

**Files:** `lib/eta/effect_blocking.ml:L1-L3`, `lib/eta/effect_concurrent.ml:L1-L3`, `lib/eta/effect_resource.ml:L1-L3`, `lib/eta/effect_island.ml:L1-L2`, `lib/eta/effect_observability.ml:L1-L3`, `lib/eta/effect_supervisor_scope.ml:L1-L2`

These comments are not harmful, but the same explanatory pattern repeats across decomposed implementation modules. It looks like a generated cleanup pass rather than documentation that helps maintainers understand each module’s unique invariants.

---

### P3 — Several comments name concepts more confidently than the code supports

**Files:** `lib/sql/eta_sql.mli:L1-L12`; `lib/sql_dsl/eta_sql_dsl.mli:L104-L119`; `lib/eta/effect.mli:L104-L110`

The SQL docs say the typed DSL prevents invalid table/column/projection combinations but immediately admit it is not a closed enforcement boundary. The island docs say worker crashes fail the outer effect as defects while `all_settled` represents worker crashes as values. Both are defensible, but the wording oscillates between strong claims and caveats.   

This is a common AI-generated-code smell: polished comments that sound architecturally complete, followed by caveats that reveal the implementation is narrower.
