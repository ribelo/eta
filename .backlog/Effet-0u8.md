---
id: Effet-0u8
title: "Survival lab: Effect.provide — does dynamic env substitution earn its place?"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T18:37:49.706Z
created_by: backlog
updated_at: 2026-05-19T23:08:02.884Z
closed_at: 2026-05-19T23:08:02.884Z
close_reason: "Completed. Provide survival lab in scratch/provide_survival/
  compared three fixtures (scoped factory, mock injection, sandbox) with and
  without Effect.provide. Decision diary V-RPv1–V-RPv5 recorded in journal.md
  lines 4801–4942. Recommendation: delete Effect.provide as unearned — no
  fixture showed a property that ordinary OCaml parameter passing lacks."
dependencies:
  - issue_id: Effet-0u8
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:45:55.155Z
    created_by: backlog
---

# Survival lab: Effect.provide — does dynamic env substitution earn its place?

## description

Review 2 §5 puts provide on probation. The R-channel auto-DI lab proved env-row works; it did not prove that mid-tree env substitution is needed at runtime. V-R10 reinstated provide by assertion ('test isolation, dynamic sub-system substitution') without three concrete fixtures that fail or become ugly without it.

Survival test: try to write three realistic effects without using Effect.provide.
1. Scoped service factory — open Db, build a sub-effect using only Db, close Db.
2. Test-local mock injection inside a larger real env — running a sub-effect with a fake Db while the rest uses the real one.
3. Sandboxed subsystem — a child program with deliberately fewer capabilities than the parent.

For each, write the version with provide and the version with ordinary OCaml (constructor passing, with_env helpers, partial application). Compare ergonomics, LOC, and how clearly intent is expressed. If the without-provide version is not materially worse, provide is unearned.

## design

scratch/provide_survival/ with three pairs of files: with_provide_X.ml and without_provide_X.ml for X in {scoped_factory, mock_injection, sandbox}. Each pair compiles. Each pair has identical behavioural tests. Compare LOC, type-signature noise, error-message quality on missing services, and call-site readability.

Honest test: ask whether the with-provide version has any property the without-provide version lacks. If the only difference is 'fewer parens at the call site', that is not enough to justify a public AST node.

## acceptance criteria

scratch/provide_survival/ contains three with/without pairs. Each pair runs identical fixtures with identical results. journal.md gains a V-RPv1..V-RPvN decision diary citing concrete LOC and ergonomic differences. Recommendation: (a) keep Effect.provide with documented rationale per fixture; (b) delete Effect.provide as unearned; (c) keep but document as 'narrow, used only at test boundaries'. 2h time budget.
