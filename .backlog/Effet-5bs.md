---
id: Effet-5bs
title: Internal fork_internal helper (V-F4)
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T14:23:57.399Z
created_by: backlog
updated_at: 2026-05-19T15:03:45.186Z
closed_at: 2026-05-19T15:03:45.186Z
close_reason: Implemented internal fork_internal in runtime.ml (not exported in
  runtime.mli), refactored detach to use it, covered completion/failure via
  existing detach tests plus runtime-switch cancellation, and nix develop -c
  dune runtest --force passes.
---

# Internal fork_internal helper (V-F4)

## description

V-F4 was decided in journal §V-F4 as 'add internal fork-and-await primitive used by Resource.auto' but explicitly NOT implemented during V-F1's par/all/for_each_par commit (journal: 'V-F4's separate fork_internal helper was not added'). Resource.auto is the documented call site (journal mentions it ~6 times since the very first sections) and remains blocked on this primitive. fork_internal stays internal — V-F2 rejected exposing public Fiber.t handles because the type system cannot prevent escape (verified via scratch/fiber_research/neg_b_escape_compiles.ml).

## design

Add fork_internal in packages/effet/runtime.ml as an internal helper, NOT exported from Runtime's public mli. Mirrors par_collect's per-call Eio.Switch + cancellation pattern but for a single effect with handle-less semantics: forks under runtime.outer_sw via Eio.Fiber.fork_daemon, increments runtime.active counter on fork, decrements on completion, swallows uncaught failures the same way Effect.detach does today. Active span key (runtime.ml:6) propagates to the child fiber so spans nest correctly. Signature roughly: val fork_internal : ('env, 'err) Runtime.t -> ('env, _, unit) Effect.t -> 'env -> unit. Used by Resource.auto and any future runtime-owned background work.

## acceptance criteria

fork_internal exists in packages/effet/runtime.ml as an internal helper (not in runtime.mli). A unit test in packages/effet/test/test_effet.ml fires fork_internal with an effect that runs to completion and verifies the runtime drains via Runtime.drain. A second test fires fork_internal with an effect that fails and confirms the parent runtime is unaffected (failure swallowed, like detach). A third test confirms cancellation: fork_internal under a cancelled outer scope stops the daemon. Existing 56-test suite continues to pass.
