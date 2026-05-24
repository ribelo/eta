---
id: Eta-tkw
title: "Major: Split effect.ml and runtime.ml into focused modules behind a
  private boundary"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-24T09:43:32.687Z
created_by: backlog
updated_at: 2026-05-24T11:54:09.787Z
closed_at: 2026-05-24T11:54:09.787Z
close_reason: Shipped — effect.ml/runtime.ml split creates effect_ast.ml,
  effect_view.ml, runtime_observability.ml, runtime_supervisor.ml (44f46a7)
dependencies:
  - issue_id: Eta-tkw
    depends_on_id: Eta-6j9
    type: parent-child
    created_at: 2026-05-24T09:44:15.871Z
    created_by: backlog
  - issue_id: Eta-tkw
    depends_on_id: Eta-jgf
    type: related
    created_at: 2026-05-24T09:44:30.220Z
    created_by: backlog
---

# Major: Split effect.ml and runtime.ml into focused modules behind a private boundary

## description

Issue: packages/eta/effect.ml grew from 339 lines on main to 1054 lines on this branch (3.1x). It now holds Island_runtime (lines 1-138, 138L), Blocking_runtime (140-501, 362L), the public AST type plus smart constructors (502-699, ~198L of top-level), public Island/Blocking wrappers (700-739), and module Private (857-1054, 198L). packages/eta/runtime.ml grew from 905 to 1182 lines and folds the interpreter, supervisor helpers, finalizer drain, retry/race/par/fork, observability/tracer wiring, and runtime construction into one file.

The five concerns inside effect.ml (island pool internals, blocking pool internals, the AST + smart constructors, observability constructors, Private re-export) are genuinely independent. The %identity boundary used in module Private (effect.ml:985) requires the duplicated AST declaration to stay structurally identical to type t — OCaml enforces this at compile time, so 'brittle' is overstated, but the duplication is real maintenance toil and a public-API leak (covered separately by Eta-jgf).

Locations:
- packages/eta/effect.ml (1054 lines, 5 concerns)
- packages/eta/runtime.ml (1182 lines, interpreter + supervisor + observability + retry/race/par)

## design

No RED test. Behavior-preserving refactor. Verification = full eta and eta-http test suites pass before and after.

Fix shape:
- Extract Island_runtime to packages/eta/island_runtime.{ml,mli} as an internal module (Dune private/wrapped). The public Effect.Island module becomes a thin wrapper over it.
- Extract Blocking_runtime to packages/eta/blocking_runtime.{ml,mli}, internal. Effect.Blocking is the thin wrapper.
- Move the AST type ('a, 'err) t and supervisor types into packages/eta/effect_ast.ml (internal). effect.ml re-exports the smart constructors.
- Pull runtime supervisor helpers (make_supervisor, fork, register_child, etc.) and observability wiring (logger/tracer/meter dispatch) into runtime_supervisor.ml and runtime_observability.ml respectively, as internal modules used by runtime.ml.
- Use a Dune (library ... (modules ...) (private_modules ...)) pattern, or a wrapped sublibrary, so the AST is visible to Runtime but not to external consumers. This is the same boundary the Effect.Private narrowing task (Eta-jgf) calls for; coordinate the two.
- Leave the public effect.mli surface unchanged (other than what Eta-jgf changes). External API must not move.

## acceptance criteria

After the refactor: packages/eta/effect.ml is materially smaller and contains only the smart-constructor surface and module wrappers. packages/eta/runtime.ml contains the interpreter dispatch and is materially smaller, with supervisor and observability extracted. AST and runtime internals are reachable only through internal Dune modules, not through the published .mli surface (except where Eta-jgf intentionally retains a small extension surface). Full eta and eta-http test suites pass before and after the refactor with no test changes required.
