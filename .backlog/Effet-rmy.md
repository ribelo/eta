---
id: Effet-rmy
title: "Tests: simultaneous-failure and finalizer-failure semantics for par /
  all / for_each_par"
status: open
priority: 3
issue_type: task
created_at: 2026-05-19T18:43:09.637Z
created_by: backlog
updated_at: 2026-05-19T18:47:46.763Z
dependencies:
  - issue_id: Effet-rmy
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:47:41.714Z
    created_by: backlog
  - issue_id: Effet-rmy
    depends_on_id: Effet-6s5
    type: blocks
    created_at: 2026-05-19T18:47:46.763Z
    created_by: backlog
---

# Tests: simultaneous-failure and finalizer-failure semantics for par / all / for_each_par

## description

Review 1 finding #8. Effect.all is fail-fast (V-F1) and returns the first failure. Earlier Cause work justified Cause.Both specifically to preserve multiple child failures. The journal does not test simultaneous-failure paths, finalizer failures during sibling cancellation, or whether Cause.Both is ever observable in all/par.

Coupling: outcome here informs Effet-6s5 (structured Cause algebra). If Both is reachable in current behaviour but never tested, that's a coverage gap. If Both is unreachable in current behaviour — i.e. fail-fast always sees one failure first — that argues against keeping Both in the typed Cause algebra at all (maybe Concurrent is empty).

Scope: tests only, no behaviour change. Establishing baseline for the cause-algebra research.

## design

packages/effet/test/test_effet.ml gains a small group of new tests that exercise edge cases:
1. Two children fail at the same instant (or as close as Eio scheduling allows) — record what Cause is observed at the parent. If Cause.Both, document; if not, note that fail-fast collapses it.
2. all with one fast failure and one sibling whose finalizer also fails — observe whether the finalizer failure surfaces or is suppressed.
3. for_each_par with two of N items failing within the cancellation window of each other.
4. nested race inside par with both branches failing at once.

The tests do not need to assert specific Cause shapes; they need to record observed behaviour so the cause-algebra research has a baseline.

## acceptance criteria

Four new tests pass under nix develop -c dune runtest --force. Each test records the observed Cause structure as part of its assertion (or alcotest message). journal.md gains a paragraph in the cause-algebra section linking back to these tests as the empirical baseline. 1h time budget.
