---
id: Effet-ztq
title: Effect.all_settled — collect all child outcomes
status: closed
priority: 3
issue_type: task
created_at: 2026-05-19T14:25:14.319Z
created_by: backlog
updated_at: 2026-05-19T15:09:05.907Z
closed_at: 2026-05-19T15:09:05.907Z
close_reason: Implemented Effect.all_settled GADT/API and runtime collector that
  runs all children without fail-fast cancellation, preserves input order,
  returns Cause values for child failures, added
  outcome/order/all-children/empty tests, and nix develop -c dune runtest
  --force passes.
---

# Effect.all_settled — collect all child outcomes

## description

Effect.all is fail-fast: the first child failure cancels siblings and rethrows. There is no way to get partial-success results across N children. Effect-TS has Effect.allSettled / { mode: 'either' } that returns each child's outcome as a result so callers can decide which subset succeeded. V-F1 explicitly defers this: 'all_settled collect-all-causes variant (deferred until demanded).' Real demand: any user that wants 'try these N things, tell me what worked' — bulk imports, parallel API calls with mixed authority, scatter-gather queries.

## design

Effect.all_settled : ('env, 'err, 'a) Effect.t list -> ('env, _, ('a, 'err Cause.t) result list) Effect.t. Implementation: forks all children under one Eio.Switch, no fail-fast cancellation, collects each child's Exit by capturing both the Cause path and the Ok path. Returns a list of result, preserving input order. The outer effect's success channel is the result list; the outer effect's error channel is open (empty row) since failures are inside the result. Implement either as combinator over fork_internal once it lands, or as a new GADT case All_settled in packages/effet/effect.ml mirroring All. Wrap each child's interpret call in a Typed_fail-aware try/catch that yields the child's Cause to the collector. Order preservation via indexed slots: pre-allocate an array of size n, each child writes to its index.

## acceptance criteria

Effect.all_settled : ('env, 'err, 'a) t list -> ('env, _, ('a, 'err Cause.t) result list) t exists in packages/effet/effect.mli with documentation. A test with three children — Effect.pure 1, Effect.fail `Boom, Effect.pure 3 — returns [Ok 1; Error (Cause.Fail `Boom); Ok 3] in input order. A test verifies all children run to completion regardless of failures (no fail-fast cancellation): with three children where the first fails immediately and the other two sleep for 50ms, all three complete and the slow ones are not cancelled. A test verifies the empty-list case returns Pure []. Existing Effect.all fail-fast tests continue to pass.
