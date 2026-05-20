---
id: Effet-yp5
title: "Survival lab: replace Duration.t with int_ms or Eio time spans"
status: open
priority: 3
issue_type: task
created_at: 2026-05-19T18:41:37.429Z
created_by: backlog
updated_at: 2026-05-19T18:47:12.647Z
dependencies:
  - issue_id: Effet-yp5
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:47:12.647Z
    created_by: backlog
---

# Survival lab: replace Duration.t with int_ms or Eio time spans

## description

Review 2 §6. Duration.t exists as a millisecond-precision nonnegative type. The journal mostly explains what Effect-TS Duration features were not ported. It does not justify Duration's existence over int_ms (a plain int) or Eio's own time abstractions.

Survival test: delete Duration.t. Replace its uses in Schedule, repeat/retry/timeout/delay, TestClock with int_ms (or Mtime.span / Eio span). Compare:
- call-site readability (Duration.ms 100 vs 100 vs Mtime.Span.of_ms 100)
- type safety: does explicit Duration.t catch any bugs that int does not? (probably not for unsigned millisecond at the API boundary)
- algebra: Schedule uses Duration's add/multiply/min/max — does int_ms cover them adequately?
- compatibility: Schedule.next_delay : t -> step:int -> Duration.t option becomes int option

If only constructor names get uglier in the no-Duration branch, the module is decorative. If type safety actually catches bugs in the Duration branch that int_ms would miss, keep it.

## design

Branch A: keep packages/effet/duration.ml as today.
Branch B: delete Duration.t; rewrite Schedule, Effect.delay/timeout, Effect.repeat/retry signatures to take int (interpreted as ms). Update TestClock to use int internally. Delete Duration.equal/pp/algebra and inline the small handful of operations Schedule needs.

Compare:
- LOC delta in core
- test readability before/after
- type signature noise
- existing TestClock virtual-time fixtures still pass

If Branch B is acceptable, the question is whether the constructor names (Duration.ms 100 vs 100) carry any documentation value worth keeping a module for.

## acceptance criteria

scratch/duration_survival/ contains both branches. The full test suite passes on each. journal.md gains a V-Dv1..V-DvN decision diary citing concrete LOC and call-site readability differences. Recommendation: (a) keep Duration.t with documented rationale; (b) replace with int_ms; (c) keep but as a thin newtype around int with no algebra (remove pp/equal/op family). 1h time budget.
