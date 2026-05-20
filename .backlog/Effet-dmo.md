---
id: Effet-dmo
title: "Property/law tests: monad laws, error-channel laws, race / retry /
  repeat / scope invariants"
status: open
priority: 3
issue_type: task
created_at: 2026-05-19T18:45:02.724Z
created_by: backlog
updated_at: 2026-05-19T18:48:39.175Z
dependencies:
  - issue_id: Effet-dmo
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:48:39.175Z
    created_by: backlog
---

# Property/law tests: monad laws, error-channel laws, race / retry / repeat / scope invariants

## description

Review 1 omission #7. V4's 'drop Pure emits' was justified from monad laws, but no law-property suite exists. Effet's interpreter manipulates a GADT; refactoring it can silently break:
- left-identity: bind (pure x) f === f x
- right-identity: bind m pure === m
- associativity: bind (bind m f) g === bind m (fun x -> bind (f x) g)
- catch left-identity: catch (pure x) h === pure x
- catch propagation: catch (bind m f) h === bind (catch m h) (fun x -> catch (f x) h)
- race symmetry / commutativity (under fail-fast, with finalizer effects)
- retry idempotence under deterministic schedules
- scope: acquire_release release runs exactly once, in reverse order of acquire, on success / fail / interrupt

Scope: a property-test suite covering at least the monad laws and the most-load-bearing combinator invariants.

## design

Use qcheck or qcheck-alcotest for property generation. Generate small Effect.t programs over a fixed env (just a counter or string accumulator), evaluate via Runtime.run, compare expected vs actual.

Generators:
- arbitrary 'a (just int for laws)
- arbitrary effects: Pure, Fail, Sync, Bind, Map, Catch with arbitrary fan-in
- arbitrary schedules with bounded depth

Properties:
1. monad laws (3 properties)
2. catch laws (2 properties)
3. race fail-fast: race [a; b] succeeds iff at least one of (a, b) succeeds (under fail-fast)
4. retry: retry sched always_true (always_succeed) === always_succeed
5. scope finalizer runs exactly once: instrument with a counter

Run via dune runtest --force as part of the standard suite. ~200 LOC of generators + properties.

## acceptance criteria

packages/effet/test/test_effet.ml gains a Properties group that runs the laws under qcheck. The suite passes under nix develop -c dune runtest --force. journal.md gains a paragraph noting which laws are now machine-checked. If a property surfaces a real bug, capture it as a P1 fix task. 2h time budget.
