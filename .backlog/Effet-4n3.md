---
id: Effet-4n3
title: "Research: supervised concurrency / nursery surface (reopen V-F2/V-F3)"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T18:36:56.015Z
created_by: backlog
updated_at: 2026-05-19T21:16:42.738Z
closed_at: 2026-05-19T21:16:42.738Z
close_reason: Explored and being implemented; journal V-Sv section records the
  decision diary. Lab-first research complete; supervision surface now in the
  implementation queue.
dependencies:
  - issue_id: Effet-4n3
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:45:15.579Z
    created_by: backlog
---

# Research: supervised concurrency / nursery surface (reopen V-F2/V-F3)

## description

Both reviews flag this as the most likely-to-flip dismissal. Review 1 finding #7 plus Review 2 §1 argue that V-F2 rejected raw public Fiber.t correctly, but the candidate set never included a first-class supervisor/nursery surface — the Trio/Eio idiom Eio's own docs call a 'nursery' or 'bundle'. The hazard is real (escaped handles compile), but the right replacement is supervision, not 'no public concurrency surface'.

Without a supervision layer Effet has structured concurrency primitives (par, all, for_each_par, scoped, race, detach) but no structured failure management. Detached failures are silently swallowed — see V-F4 close reason and the journal's own admission that detached fiber failures still need a future diagnostics/supervision surface.

Resource.auto already exists, so the pressure point V-F4 deferred is now active.

Hypotheses to lab (all on equal footing):
- F-D Supervisor scope: Supervisor.scoped (fun sup -> ...) returns a scope inside which start/await/cancel produce a child handle bound to the scope; handle cannot escape. Failures observable via supervisor; not propagated by default.
- F-E Supervisor strategies: One_for_one / One_for_all + restart policies (Never / On_failure / Always), shaped after OTP supervision trees.
- F-F Nursery as ambient: a thread-local-like supervisor accessible via Effect.t inside a scope; similar to Trio's open_nursery() with async-with.
- F-G Stay with detach + rebuild Resource.auto on a typed sink: prove supervision is unnecessary.

## design

Lab-first per V-R10. Build scratch/supervision_research/ with each candidate as a self-contained module. Use rank-2 polymorphism or scope phantom types to prevent handle escape statically (V-F3 proved this works in OCaml 5.4). Negative tests: handle leaks out of scope must fail to compile.

Required positive fixtures:
- start a child whose fail is observable on the supervisor without failing the parent
- await a child's typed result inside the scope
- cancel a child mid-flight, finalizers run
- supervisor itself fails on N child failures (configurable threshold)
- nested supervisors compose; inner failure does not unwind outer unless the outer wants it

Required negative fixtures:
- child handle returned outside Supervisor.scoped is a compile error
- await on a cancelled child does not deadlock

Compare against current Effect.detach behaviour: under each hypothesis, can we re-implement Resource.auto without swallowing failures, and what is the LOC/ergonomic cost?

## acceptance criteria

scratch/supervision_research/ contains at least F-D and F-E as compiling modules with positive and negative tests, plus runtime smoke tests. The lab proves whether handle escape can be statically prevented for at least one candidate. journal.md gains a V-Sv1..V-SvN decision diary with a final recommendation: keep current detach-only model, adopt one of F-D/F-E/F-F, or reopen as a follow-up. If a candidate is recommended, a follow-up backlog task captures the implementation slice. Detach's failure-swallowing behaviour is either justified by the lab (and recorded as such) or replaced with an observable sink. 2.5h time budget.
