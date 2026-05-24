---
id: Eta-jgf
title: "P2: Narrow Effect.Private surface (no red test — API reshape)"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-24T09:05:39.212Z
created_by: backlog
updated_at: 2026-05-24T10:38:51.177Z
close_reason: "Closed by remediation. Removed the interpreter AST view from the public Effect.Private mli, moved runtime pattern matching to Dune-private effect_view, documented the remaining Private runtime hooks, and replaced eta-schema-test's public AST usage with Runtime.run. Verified with nix develop -c dune runtest --force."
comments:
  - id: 1
    issue_id: Eta-jgf
    author: backlog
    text: "Second review pass added context: the AST is duplicated in module Private
      via 'type ('a, 'err) view = ('a, 'err) t = | Pure ... | Fail ...'
      (effect.ml:858) plus 'external view : t -> view = \"%identity\"'
      (effect.ml:985). This is OCaml type-equality re-export, which the compiler
      enforces structurally — declarations diverging from t fail to compile, so
      'brittle' framing in the second review is overstated. The underlying claim
      (Private leaks the AST publicly) is the same finding this task already
      covers. The recommended fix is unchanged: move the AST and Private-access
      surface behind a Dune private/wrapped library so Runtime sees the AST
      without publishing it. Coordinate landing this with Eta-tkw
      (effect.ml/runtime.ml split), since they share the boundary. Source:
      second code review, claim 2."
    created_at: 2026-05-24T09:44:38.786Z
---

# P2: Narrow Effect.Private surface (no red test — API reshape)

## description

Issue: packages/eta/effect.mli lines 477–706 expose module Private with the entire interpreter view GADT (every constructor: Pure, Fail, Sync, Island×4, Blocking, Bind, Map, Catch, Tap_error, Delay, Timeout×2, Concat, Race, Par, All, All_settled, For_each_par×2, Daemon, Uninterruptible, Repeat, Retry, Acquire_release, Scoped, Supervisor_scoped, Render_error, Suppress_observability, Named, Named_attrs, Annotate, Link_span, With_external_parent, With_context, Current_span, Current_context, Log, Metric_update×3) plus view, daemon, metric_updates×2, island_submit×4, blocking submit/event types, make_supervisor and supervisor_fork/record_failure/failures/register_child/cancel_children, child constructor accessors. Anyone downstream can pattern-match on the AST; future runtime changes are SemVer-breaking.

Location: packages/eta/effect.mli module Private

## design

No red test. Per the user rule, no tests that check what is public vs private.

Fix shape:
- Move runtime-private view into an internal library (Dune wrapped/internal modules, e.g., a private sublibrary that only sibling packages inside this repo can see).
- Audit each in-repo consumer (eta-http, eta-otel, eta-stream, eta-test) for actual Private usage. Replace with public APIs where possible.
- If cross-package internal access remains necessary, split into two pieces: stable public extension points (a small documented set) vs unstable internal constructors hidden from external consumers.
- Update Dune package stanzas accordingly; document the reduced public Private surface in effect.mli.

## acceptance criteria

Effect.Private is no longer in the public mli, or is reduced to a small explicit set of necessary extension points (each documented). All in-repo callers continue to build. An external consumer using only public Effect.t and constructors continues to build and run unchanged.
