---
id: Eta-18v
title: "P3: Rename or document Effect.collect_names limitation (no red test)"
status: closed
priority: 3
issue_type: task
created_at: 2026-05-24T09:07:27.302Z
created_by: backlog
updated_at: 2026-05-24T11:12:37Z
close_reason: "Closed by remediation. Kept the existing Effect.collect_names API and documented in effect.mli that it returns only statically present names, skips continuation-producing nodes, and is not a complete runtime inventory. Audited usages outside backlog metadata; only the focused test suite calls it. Verified with nix develop -c dune runtest packages/eta/test --force."
---

# P3: Rename or document Effect.collect_names limitation (no red test)

## description

Issue: packages/eta/effect.ml collect_names walks only statically present subtrees and intentionally skips continuation-producing nodes (Bind, Catch, For_each_par, Supervisor_scoped). The name implies a complete inventory; the function is monadic-AST-incomplete by construction. If used for observability inventory or completeness claims, it silently misses dynamic effects.

Location: packages/eta/effect.ml collect_names

## design

No red test. Naming and documentation only.

Fix shape:
- Rename to collect_static_names, OR update the .mli docstring to state explicitly that continuations are not traversed and the function is for documentation/preflight only, not for completeness claims.
- Audit observability and metric code for usages that rely on completeness; replace if any.

## acceptance criteria

The name or docstring makes the limitation observable from the .mli alone. Existing usages still compile. No usage relies on the function for completeness.
