
 1. Structural regression (headline): the "child scope with finalizers" pattern is
 copy-pasted 9 times and has already silently diverged

 This is the root cause behind "we keep having issues with cancelling effects /
 releasing resources." The exact incantation

 ```ocaml
   let finalizers = ref [] in
   let child_frame = { frame with sw; finalizers } in
   Runtime_core.with_finalizers ~runtime:frame.runtime ~fail_key:frame.fail_key
     ~error_renderer:child_frame.error_renderer finalizers (fun () ->
       run_to_value child_frame effect)
 ```

 appears, with small hand-tuned variations, in:

 - effect_resource.ml: run_cleanup_to_exit, acquire_release (release closure), scoped
 - effect_supervisor_scope.ml: Supervisor_start, supervisor_scoped
 - effect_concurrent.ml: run_child
 - effect_core.ml: timeout_as, repeat, retry

 Nine sites, each independently deciding:
 - whether to pass a fresh sw,
 - whether to wrap in try ok (...) with exn -> exit_of_exn or call run_to_value (which
 itself raises) inside with_finalizers,
 - which error_renderer to use.

 That last divergence is a real latent bug, not a style nit. In
 effect_supervisor_scope.ml the child frame is built as:

 ```ocaml
   let child_frame =
     { frame with sw; finalizers; error_renderer = default_renderer }
 ```

 while every other site inherits frame.error_renderer. default_renderer _ = "<typed
 failure>". So a typed failure raised inside a supervised child renders as the opaque
 "<typed failure>" in its cause diagnostic, whereas the identical failure under
 par/race/timeout/scoped renders with the user's real renderer. This is exactly the kind
 of bug that hides because the pattern was copied rather than centralized.

 Code-judo remedy. Collapse all nine into one canonical primitive in effect_core.ml:

 ```ocaml
   (* one authority for "run [effect] in a fresh finalizer scope, optionally a
      fresh switch, returning an Exit instead of raising". *)
   let run_scope ?sw frame effect =
     let finalizers = ref [] in
     let sw = Option.value sw ~default:frame.sw in
     let child_frame = { frame with sw; finalizers } in
     try
       ok (Runtime_core.with_finalizers
             ~runtime:frame.runtime ~fail_key:frame.fail_key
             ~error_renderer:child_frame.error_renderer finalizers
             (fun () -> run_to_value child_frame effect))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn -> exit_of_exn child_frame exn
 ```

 Then run_child, the timeout_as body fiber, repeat/retry iterations, scoped, and the
 supervisor child body all become one-liners. The cancellation/finalizer contract gets
 proven once, and the renderer divergence disappears by construction. If supervisor
 children genuinely need a different renderer, that becomes an explicit ?error_renderer
 argument with a comment — not an accident.

 This single move removes the most dangerous source of "cancellation behaves differently
 in different combinators."

 ────────────────────────────────────────────────────────────────────────────────

 2. Effect_resource.finally hand-rolls the suppressed-cause algebra that with_finalizers
  already owns

 finally is ~40 lines that manually match Ok / Error primary / Cancelled / other exn and
 reconstruct Cause.suppressed ~primary ~finalizer. Runtime_core.with_finalizers already
 does precisely this composition (same four arms, same Cause.suppressed /
 Cause.interrupt handling). So the most delicate invariant in the codebase — how a
 primary failure composes with a cleanup failure under cancellation — is implemented
 twice, in two files, and must be kept in sync by hand.

 finally cleanup effect is semantically "run effect in a scope whose sole finalizer is
 cleanup." It should be expressible as: register cleanup as a finalizer, then run under
 with_finalizers. That deletes the duplicate algebra entirely and guarantees finally and
 scoped/acquire_release can never drift in how they suppress/aggregate causes. This is a
 delete-complexity move, not a rearrange-complexity move.

 (run_cleanup_to_exit is itself a third partial re-implementation of the same
 finalizer-run-to-exit idea — folds into run_scope above.)

 ────────────────────────────────────────────────────────────────────────────────

 3. C memory leak (confirmed): asymmetric cleanup in ladybug_stubs.c create_lbug_map

 In the OOM/error path:

 ```c
   keys[i] = api.value_create_string(key);
   vals[i] = create_lbug_value(Field(pair, 1), copies);
   if (keys[i] == NULL || vals[i] == NULL) {
     if (vals[i] == NULL && keys[i] != NULL) api.value_destroy(keys[i]);
     destroy_lbug_values(keys, i);   /* frees 0..i-1 only */
     destroy_lbug_values(vals, i);   /* frees 0..i-1 only */
     return NULL;
   }
 ```

 Case keys[i] == NULL && vals[i] != NULL: the special if is false (because vals[i] !=
 NULL), and both destroy_lbug_values(_, i) calls stop at i-1. vals[i] (a live
 lbug_value*) is leaked. This is the hand-written, asymmetric, special-cased cleanup the
 review standard explicitly flags. create_lbug_list and create_lbug_struct handle their
 partial state more uniformly; create_lbug_map is the odd one out.

 Remedy (delete the special case): store both into the arrays unconditionally and always
 free index i too — e.g. on failure do destroy_lbug_values(keys, i + 1);
 destroy_lbug_values(vals, i + 1); after ensuring any not-yet-created slot is NULL
 (calloc already guarantees that). destroy_lbug_values already null-checks each slot, so
 a single symmetric i + 1 cleanup covers every combination and the bespoke if (vals[i]
 == NULL && keys[i] != NULL) branch vanishes.

 This is hard to exercise from a ref test (it's an allocation-failure path), so the
 right move is to make the structure obviously-correct rather than relying on a test.
 Worth a code comment documenting the invariant.

 ────────────────────────────────────────────────────────────────────────────────

 4. Boundary/duplication: the three driver pools triplicate ~80 lines of orchestration
 each

 lib/sql/pool.ml, lib/turso/pool.ml, and lib/duckdb/pool.ml each independently define
 near-identical:

 - to_public_error / to_raw_error
 - map_*_result
 - blocking_result
 - detach_started_blocking_pool_error + reject_detach_started_blocking_pool
 - timed_blocking_result (the cancellation-critical one: ~on_cancel:interrupt
 ~on_timeout:Timeout`)

 The Detach_started-rejection logic and the interrupt-on-cancel wiring are the
 cancellation-sensitive parts, and they're copy-pasted across three packages. If you fix
 a cancellation bug in one (e.g., a missed reject_detach_started), the other two
 silently keep the bug. Note turso/pool.ml doesn't even have a timed/interrupt variant —
 its leased_blocking_result has no on_cancel interrupt at all, so a cancelled Turso
 query cannot interrupt the in-flight C sqlite3_step, unlike sql and duckdb. That's an
 asymmetry worth confirming is intentional, not an oversight.

 Remedy: extract a small shared "leased blocking resource" helper (a functor over {
 raw_error; to_public; interrupt }) that owns timed_blocking_result +
 reject_detach_started. The package-boundary policy doesn't forbid this — the helper
 carries no external deps; it lives in eta or a tiny shared module and each driver
 supplies its error mapping + interrupt function. This makes the interrupt-on-cancel
 contract uniform across all three drivers.

 ────────────────────────────────────────────────────────────────────────────────

 5. Smaller, lower-confidence notes

 - Eta.Pool.with_lock vs Eio.Mutex.use_ro/use_rw. pool.ml uses a raw lock +
 Fun.protect-unlock (with_lock) for write sections, but use_ro/use_rw ~protect
 elsewhere. Today every with_lock body is pure OCaml (no suspension → no cancellation
 point inside), so it's safe. But the module comment claims "single transition
 authority," and the safety depends on an unstated "no Effect suspension under the lock"
 invariant. Either route everything through use_rw ~protect:true or document the
 invariant explicitly at with_lock.
 - DuckDB connect/appender_create custom-block ordering. eta_duckdb_connect and
 eta_duckdb_appender_create allocate the custom block after obtaining the live handle,
 whereas sqlite/turso allocate the block first (NULL) then fill it. Since
 caml_alloc_custom can't raise (it aborts on OOM), there's no leak today — but the
 codebase has two opposite conventions for the same "wrap a C handle in a finalizable
 block" job. Pick the allocate-first convention everywhere; it's the one that's robust
 if allocation behavior ever changes, and it removes a "why is this one different?"
 question.
 - eta_duckdb_connect runs outside a blocking section. api.connect is called without
 caml_enter_blocking_section, unlike open/query/execute. For in-process DuckDB it's
 fine; flag only to confirm it's deliberate.

 ────────────────────────────────────────────────────────────────────────────────

 Suggested ref tests (to lock down the above before/after fixes)

 1. Supervised-child renderer (catches #1 today): supervise a child that fails with a
 typed error using a custom error_renderer; assert the rendered cause is the custom
 string, not "<typed failure>". This currently fails.
 2. Uniform cancellation/cleanup across combinators: a resource whose release records an
 event, wrapped under each of scoped, finally, par, race loser, timeout body, repeat,
 retry; assert release fires exactly once and finalizer diagnostics compose identically
 when both body and cleanup fail. This is the regression net that makes the #1 refactor
 safe.
 3. Turso cancel → interrupt: a long-running Turso query under timeout; assert the C
 step is interrupted (mirrors the existing sql/duckdb on_cancel tests). If it can't be,
 that confirms #4's asymmetry is a real gap.
 4. Pool release under outer cancellation: acquire from Eta.Pool.with_resource, cancel
 the caller mid-body; assert the connection is returned/closed (accounting active→0,
 closed incremented) and not leaked — exercising the finalizer-under-cancel_protect path
 that #1 centralizes.
