
I reviewed the uploaded Repomix package as the source of truth. It is complete enough for architecture/code review, but incomplete for judging test coverage because the package explicitly excludes tests/bench/docs-style areas from the code payload. 

## 1. Correctness Review

### P0 — Unsound generic array initialization in `Eta.Par.Array.par_map` / `par_mapi`

**Files:** `lib/eta/par_array.ml:51-58`, `lib/eta/par_array.ml:72-78`; exposed via `lib/eta/par.ml` / `lib/eta/par.mli`.

`par_map` and `par_mapi` allocate the output with:

```ocaml
Array.make n (Obj.magic 0 : 'b)
```

For a generic `'b array`, this is unsafe. It is especially dangerous when `'b = float`, because OCaml uses a specialized float-array representation; `Obj.magic 0 : float` is not a valid boxed/float value. This can corrupt representation assumptions or crash. The function is public as `Eta.Par.par_map`/`par_mapi`, so ordinary users can hit it by mapping to floats or other representation-sensitive values. 

### P0 — Native stubs have null/closed-handle dereference paths

**Files:** `lib/turso/turso_stubs.c:249-264`, `lib/turso/turso_stubs.c:300-348`, `lib/ladybug/ladybug_stubs.c:642-659`.

The Turso C stubs call SQLite/Turso function pointers with `stmt_val(v_stmt)` or `db_val(v_db)` without consistently checking for null/closed handles. For example, `eta_turso_prepare` passes `db` directly to `api.prepare_v2`, and column/bind functions call `api.column_*` / `api.bind_*` directly on `stmt_val`. If OCaml code reaches these through a finalized/closed statement or database, this can turn a normal misuse into a C crash.

Ladybug has a separate null-name crash: `struct_properties` reads `schema->children[idx]->name` and immediately passes it to `strcmp` when skipping graph fields. Later code handles null names defensively, so this looks like an inconsistent C stub assumption rather than an intentional invariant.

### P1 — SQLite backup/restore can busy-spin indefinitely

**File:** `lib/sql/sqlite_stubs.c:903-989`.

`eta_sqlite_backup_between` retries while `sqlite3_backup_step` returns `SQLITE_OK`, `SQLITE_BUSY`, or `SQLITE_LOCKED`:

```c
do {
  rc = sqlite3_backup_step(backup, 128);
} while (rc == SQLITE_OK || rc == SQLITE_BUSY || rc == SQLITE_LOCKED);
```

There is no sleep, retry budget, interrupt check, progress check, or backoff. Backup/restore wraps this inside a blocking section, so the OCaml runtime lock is released, but the OS thread can still spin at 100% CPU until the lock clears. In a pool, this can silently consume blocking capacity. 

### P1 — Pool shutdown and eviction suppress close/release failures

**Files:** `lib/eta/pool.ml:237-263`, `lib/eta/pool.ml:490-521`.

`close_entry` preserves release failures by converting them to `Effect.fail`. But `close_entries` runs all closes with `Effect.all_settled` and then discards every result:

```ocaml
|> Effect.all_settled
|> Effect.map (fun _ -> ())
```

`begin_shutdown` uses `close_entries` for idle resources, so shutdown can return success even if one or more resource releases failed. This hides real cleanup failures and can make DB/connection leaks look like clean shutdown. 

### P1 — Supervisor child registrations are never removed

**Files:** `lib/eta/runtime_supervisor_types.ml:1-7`, `lib/eta/runtime_supervisor.ml:30-43`, `lib/eta/effect_supervisor_scope.ml:56-103`.

Every `Supervisor_start` registers a child cancel closure in an atomic list, but there is no deregistration when the child resolves. Long-lived supervisor scopes that start many short-lived children accumulate stale closures until scope exit. At scope exit, `cancel_children` iterates all of them, including completed children. This is a lifecycle leak and can become user-visible memory/finalization overhead in servers or background supervisors.

### P2 — `tap_error` does not observe typed failures inside composite causes

**Files:** `lib/eta/effect_core.ml:227-263`, `lib/eta/effect.mli:360-369`.

`catch` and `map_error` traverse typed failures inside `Sequential` and `Concurrent` causes, but `tap_error` only handles the exact shape `Exit.Error (Cause.Fail err)`. That means failures produced by parallel composition are not observed, even though the public documentation says it runs an observer “when the effect fails with a typed error.” This is inconsistent with the rest of the typed-error API. 

### P2 — Ladybug Arrow materialization is not exception-safe for native releases

**File:** `lib/ladybug/ladybug_stubs.c:744-779`.

`materialize_arrow_rows` obtains an Arrow schema and chunk arrays, then allocates many OCaml strings/tuples while holding native resources. If any OCaml allocation raises, the function skips `array.release` and/or `schema.release`. This is a native resource leak on allocation failure or unexpected OCaml exception inside row materialization.

### P2 — SQL DSL soundness is explicitly not an enforcement boundary

**Files:** `lib/sql/connection.mli:1-21`, `lib/sql/pool.mli:1-48`, `lib/sql/eta_sql.mli:1-11`.

The typed SQL DSL does protect typed builders from many table/column/projection mismatches, but the package deliberately exposes raw query/execute/execute_script escape hatches. The public docs say callers using raw operations own SQL validity, parameter ordering, and result decoding. This is acceptable as an escape hatch, but it means the DSL is a construction aid, not a closed soundness boundary. Security-sensitive users should not treat `Eta_sql` as preventing invalid SQL globally.

## 2. Code Quality Review

### P1 — Public `Effect.run` leaks a private implementation module

**Files:** `lib/eta/dune:5-23`, `lib/eta/effect.mli:603-605`, `lib/eta/runtime.ml:13-20`, `lib/eta/runtime.mli:1-20`.

`runtime_core` is declared private in dune, but `Effect.mli` exposes:

```ocaml
val run : 'err Runtime_core.t -> ...
```

That couples the public interface to a private module path. `Runtime.mli` correctly abstracts the runtime as `type 'err t`, but `Effect.mli` pierces that abstraction. This creates documentation/build fragility and makes the boundary between public and internal runtime APIs unclear.

### P2 — Several modules are too large to review or evolve safely

Large modules in the package include:

| File                               | Approx. LOC | Problem                                                                                                        |
| ---------------------------------- | ----------: | -------------------------------------------------------------------------------------------------------------- |
| `lib/sql/sqlite_stubs.c`           |         995 | Driver loading, DB lifecycle, statements, values, backup/restore all in one C file.                            |
| `lib/ladybug/ladybug_stubs.c`      |         966 | Dynamic loader, query execution, Arrow decoding, graph conversion, and OCaml allocation mixed.                 |
| `lib/sql_dsl/eta_sql_dsl_query.ml` |         929 | Schema, expressions, scopes, projection, select/insert/update/delete rendering in one functor.                 |
| `lib/stream/eta_stream.ml`         |         817 | Core stream AST, interpreters, file sources, merge, flat_map_par, retry-like concurrency in one module.        |
| `lib/ai/eta_ai.mli`                |         728 | Provider core, all AI request/response types, transport, streams, observability in one public interface.       |
| `lib/sql/sqlite.ml`                |         719 | Low-level SQLite wrapper, stepping, statement lifecycle, transaction helpers, migrations-adjacent operations.  |
| `lib/eta/effect.mli`               |         650 | Public effect core, runtime internals, blocking, islands, supervisor, tracing, resources all in one signature. |
| `lib/eta/pool.ml`                  |         523 | Admission, lifecycle state machine, eviction daemon, observability, shutdown, metrics all together.            |

The issue is not merely file length; the long files combine independent invariants that need different review skills. The C stubs show this directly: duplicated patterns are already inconsistent between SQLite, Turso, DuckDB, and Ladybug.

### P2 — Provider facade duplication creates a wide but shallow API surface

**Files:** `lib/ai/openai/eta_ai_openai.ml:1-63`, `lib/ai/openrouter/eta_ai_openrouter.ml:1-84`.

The OpenAI and OpenRouter facades mostly re-export endpoint helpers, create alias functions, then wrap those aliases again in endpoint modules. This creates many public names with very little behavior difference. It increases maintenance cost because endpoint additions require touching common plumbing, endpoint implementation, facade aliases, nested modules, and `.mli` declarations. The duplication is visible in the repeated `encode_*`, `*_request`, `run`, and nested `module Images/Speech/Transcriptions/...` shapes.

### P2 — SQL DSL builder style is inefficient and hard to evolve

**File:** `lib/sql_dsl/eta_sql_dsl_query.ml:465-650`, `lib/sql_dsl/eta_sql_dsl_query.ml:660-783`.

The DSL uses repeated list appends such as `existing.params @ on.Expr.params`, `query.values @ [ ... ]`, and `params query @ projection.params` while also manually rendering SQL with many local `Buffer` fragments. This is manageable for small queries, but it makes large query construction O(n²) in some builder paths and scatters parameter-ordering invariants across many functions.

### P2 — C-stub safety conventions are not centralized

**Files:** `lib/sql/sqlite_stubs.c`, `lib/turso/turso_stubs.c`, `lib/duckdb/duckdb_stubs.c`, `lib/ladybug/ladybug_stubs.c`.

The stubs repeat dynamic loading, custom-block finalizers, close/finalize paths, C-string copying, blocking-section management, and OCaml allocation-after-native-acquire patterns. The repeated code is not just duplication; it has diverged in safety. SQLite has more null checks around column access than Turso; Ladybug handles null field names in one materializer but not another; DuckDB/Ladybug have several native-release-after-allocation patterns. This should be treated as an architectural quality issue, not isolated C nits.

### P3 — Some docs expose unresolved research context as public API narrative

**File:** `lib/eta/supervisor.mli:1-13`.

The supervisor docs mention an “H3 portable supervisor path” and stable task-index ordering, while the packaged library exposes same-domain supervision only. That leaks research vocabulary into the stable public docs and may confuse users about guarantees that do not exist in this package.

## 3. AI Slop Review

### P2 — Stale research concepts appear in polished public documentation

**File:** `lib/eta/supervisor.mli:7-13`.

The public supervisor docs discuss H3 portable failure snapshots even though this package is the pure library pass and the implementation underneath is same-domain `Runtime_supervisor`. This is the strongest “AI slop” signal I saw: a plausible architectural note that may be true in some adjacent design document, but is not grounded in the actual public module shipped here.

### P2 — Wrapper/facade layers add names without adding behavior

**Files:** `lib/ai/openai/eta_ai_openai.ml:10-63`, `lib/ai/openrouter/eta_ai_openrouter.ml:6-84`.

The AI providers contain many one-line aliases and tiny modules that mechanically rename the same operations. This looks like endpoint-surface generation rather than a hand-curated API. The result is not obviously incorrect, but it creates a “large surface, small substance” smell: users see many modules and functions, while maintainers must keep alias matrices synchronized.

### P3 — Comments sometimes justify structure instead of enforcing it

**Files:** `lib/eta/pool.ml:1-5`, `lib/eta/effect_concurrent.ml:158-161`.

The pool file starts with a prose defense for keeping many invariants in one module, and `effect_concurrent.ml` has an implementation note about frame-wrapping requirements. These comments are plausible, but they are also compensating for code organization that is hard to verify locally. In a cleaned-up codebase, those invariants would be smaller, named, and mechanically enforced by narrower module boundaries.

### P3 — Defensive JSON/provider boilerplate is repeated across providers

**Files:** `lib/ai/openai/images.ml:6-42`, `lib/ai/openrouter/images_impl.ml:9-65`, plus adjacent speech/transcription/video modules.

The provider modules repeatedly implement the same pattern: validate a few fields, build a JSON object, parse response JSON, map optional usage, attach raw text. Some validation is necessary, but the repetition has an AI-generated feel because the structure is copied endpoint-by-endpoint rather than abstracted around a small codec pattern. This increases the chance that one endpoint gets validation or error decoding subtly wrong.

### P3 — Public interfaces are over-documented in ways that obscure the critical contracts

**Files:** `lib/eta/effect.mli`, `lib/ai/eta_ai.mli`, `lib/duckdb/eta_duckdb.mli`.

The public signatures contain extensive prose, but the most critical invariants are sometimes buried: non-preemptive cancellation for blocking/islands, raw SQL escape hatches, C-stub lifecycle assumptions, and supervisor failure ordering. The problem is not “too many comments” by itself; it is that obvious API descriptions and future-scope notes compete with the few contracts users must internalize to avoid misuse.

## Highest-priority repair queue

1. Fix `Eta.Par.Array.par_map` / `par_mapi` before shipping `Eta.Par` broadly.
2. Audit Turso and Ladybug stubs for null handles, null names, and release-on-exception paths.
3. Make SQLite backup/restore bounded or cooperative instead of busy-spinning.
4. Decide whether `Eta.Pool.shutdown` should fail, aggregate, or explicitly report close failures instead of discarding them.
5. Remove the public `Runtime_core.t` leak from `Effect.mli`.
6. Clean public docs of H3-only promises unless those paths are present in this package.
