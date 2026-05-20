---
id: Effet-c4c
title: Effect.for_each_par_bounded — capped parallelism
status: closed
priority: 3
issue_type: task
created_at: 2026-05-19T14:25:27.159Z
created_by: backlog
updated_at: 2026-05-19T15:10:35.811Z
closed_at: 2026-05-19T15:10:35.811Z
close_reason: Implemented Effect.for_each_par_bounded with max validation,
  semaphore-backed capped parallelism, input-order results, fail-fast behavior
  matching for_each_par, tests for cap/order/max=1/fail-fast, and nix develop -c
  dune runtest --force passes.
---

# Effect.for_each_par_bounded — capped parallelism

## description

Effect.for_each_par runs all items concurrently; for large input lists this saturates the system (DB connections, file descriptors, downstream rate limits). Real users hit this immediately with for_each_par over arrays of 100+ items. Effect-TS has Effect.forEach { concurrency: N } or Effect.forEachPar with concurrency option. V-F1 defers: 'Effect.parallel_collection with bounded parallelism (semaphore-style).'

## design

Effect.for_each_par_bounded : max:int -> 'x list -> ('x -> ('env, 'err, 'a) t) -> ('env, 'err, 'a list) t. Implementation: an Eio.Semaphore.t with max permits is acquired by each child before running and released on completion. Same fail-fast semantics as for_each_par: first child failure releases its permit and cancels the entire switch. Order preservation via indexed slot array. Either a new GADT case For_each_par_bounded mirroring For_each_par with an extra max field, or a combinator over for_each_par with semaphore wrapping each f x. Edge: max=0 should fail fast with `Invalid_argument; max=1 reduces to sequential for_each. Validate max > 0 at smart-constructor time.

## acceptance criteria

Effect.for_each_par_bounded ~max:int -> 'x list -> ('x -> ('env, 'err, 'a) t) -> ('env, 'err, 'a list) t exists in packages/effet/effect.mli with documentation. A test with max:2 and 5 items, each item incrementing a shared counter on entry and decrementing on exit, verifies the counter never exceeds 2 (concurrency cap honored). A test verifies result order matches input order. A test verifies failure semantics match for_each_par: first child failure cancels the rest. A test verifies max=1 produces sequential execution. Existing for_each_par tests continue to pass.
