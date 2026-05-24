---
id: Eta-onp
title: "P3: Keep Effect.sync canonical; remove stale old spelling"
status: closed
priority: 3
issue_type: task
created_at: 2026-05-24T09:07:18.743Z
created_by: backlog
updated_at: 2026-05-24T11:13:37Z
close_reason: "Closed by user correction. Effect.sync is the canonical API; no thunk alias was added. Verified no stale dotted old spelling remains outside journal.md and scratch/, which are excluded by user instruction."
---

# P3: Keep Effect.sync canonical; remove stale old spelling

## description

Issue: the review task was superseded by the user correction that
`Effect.sync` is the canonical API. Do not introduce a thunk alias or migrate
callers away from `Effect.sync`.

Location: packages/eta/effect.mli line 53 (val sync)

## design

No red test. Pure metadata/codebase cleanup; behavior is unchanged.

Fix shape:
- Keep `Effect.sync` as the public API and documented spelling.
- Do not add a thunk alias.
- Remove stale dotted old spelling from tracked files, except historical
  `journal.md` and `scratch/` content which the user explicitly excluded.

## acceptance criteria

`Effect.sync` exists and remains the documented form. No thunk alias exists.
Search for the stale dotted old spelling has no matches outside `journal.md`
and `scratch/`.
