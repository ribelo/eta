---
id: Effet-j40
title: "Survival lab: Effect.detach — delete-or-supervise"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T18:37:35.084Z
created_by: backlog
updated_at: 2026-05-19T22:12:09.249Z
closed_at: 2026-05-19T22:12:09.249Z
close_reason: "Completed. Detach survival lab (V-RDv1–V-RDv8) concluded: public
  Effect.detach removed, internal Daemon kept for Resource.auto, runtime hook
  removed, type made abstract. Full project gate passes. See journal.md lines
  4333–4527 for full decision diary."
dependencies:
  - issue_id: Effet-j40
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:45:37.437Z
    created_by: backlog
  - issue_id: Effet-j40
    depends_on_id: Effet-4n3
    type: blocks
    created_at: 2026-05-19T18:45:42.673Z
    created_by: backlog
comments:
  - id: 1
    issue_id: Effet-j40
    author: backlog
    text: Blocking dependency Effet-4n3 (supervision research) is closed —
      supervision surface explored and being implemented. Effet-j40's Branch A
      (delete detach, use Supervisor) now has a concrete target. Re-evaluate
      whether this survival lab is still needed given the supervision
      implementation work happening, or whether detach's fate is decided by the
      supervisor's design.
    created_at: 2026-05-19T21:16:46.937Z
---

# Survival lab: Effect.detach — delete-or-supervise

## description

Review 2 §1 calls Effect.detach 'the worst offender' and 'the clearest abstraction created before proving need'. The journal justifies detach by future Resource.auto and child workflows, while admitting it swallows failures in a typed-failure library. Resource.auto now exists and uses detach internally, so the future call site is here.

Survival test: delete Effect.detach from the public API, then try to implement every current feature and example without it. If only Resource.auto breaks, evaluate whether Resource.auto can be rebuilt on supervision (depends on Effet-4n3 outcome) or on a typed runtime sink that records detached failures observably.

This is a deletion-pressure lab: the hypothesis is that detach should not exist as a public effect in its current form. The lab must either (a) confirm by showing Resource.auto and any other call sites can be rebuilt cleanly without detach, or (b) refute by showing detach has independent value beyond Resource.auto.

## design

Two parallel implementations:
- Branch A: Effect.detach removed from effect.mli; Resource.auto re-implemented on Supervisor (or a runtime failure sink) directly. Internal fork_internal can stay, but no detach AST node.
- Branch B: Effect.detach kept, but failure-swallowing replaced with a typed runtime ?on_detached_failure : 'a Cause.t -> unit hook on Runtime.create.

Run the existing 56+ test suite against each branch. Measure LOC delta, public API surface change, and observability gain (does a previously-silent failure now surface?).

Coupled with Effet-4n3: if supervision lab recommends F-D/F-E/F-F, this lab uses that surface for Branch A. If supervision lab keeps detach-only, Branch B is the only option.

## acceptance criteria

scratch/detach_survival/ exists with two branches; existing detach behaviour either removed or replaced with observable sink; journal V-RDv decision diary recorded; follow-up implementation task created if a behaviour change is recommended.
