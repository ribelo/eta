---
id: Eta-onp
title: "P3: Rename Effect.sync to Effect.sync (no red test — pure rename)"
status: closed
priority: 3
issue_type: task
created_at: 2026-05-24T09:07:18.743Z
created_by: backlog
updated_at: 2026-05-24T11:54:09.787Z
closed_at: 2026-05-24T11:54:09.787Z
close_reason: Fixed — part of code review remediation commit (44f46a7)
---

# P3: Rename Effect.sync to Effect.sync (no red test — pure rename)

## description

Issue: packages/eta/effect.mli line 53 exposes 'val sync : (unit -> 'a) -> ('a, 'err) t'. Journal records the design preference for thunk since Eio has no JS-style sync/async function-color split; sync carries misleading Effect-TS connotations.

Location: packages/eta/effect.mli line 53 (val sync)

## design

No red test. Pure rename; behavior is unchanged.

Fix shape:
- Add 'val thunk : (unit -> 'a) -> ('a, 'err) t' as the primary name.
- Either remove val sync (if SemVer permits at this stage), or keep it as a deprecated alias for one release with [@@ocaml.deprecated 'use Effect.sync'].
- Migrate internal call sites (runtime.ml, transport/connect.ml, client/*, h1/*, h2/*, etc.) to Effect.sync.
- Update README/docs and any mli docstrings that mention sync.

## acceptance criteria

Effect.sync exists and is the documented form. Effect.sync is either removed or deprecated with a clear pointer to Effect.sync. All in-repo callers use Effect.sync.
