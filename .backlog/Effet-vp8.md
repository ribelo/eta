---
id: Effet-vp8
title: "Survival lab: ppx_effet — golden tests or removal"
status: open
priority: 3
issue_type: task
created_at: 2026-05-19T18:41:53.406Z
created_by: backlog
updated_at: 2026-05-19T18:47:20.574Z
dependencies:
  - issue_id: Effet-vp8
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:47:20.574Z
    created_by: backlog
---

# Survival lab: ppx_effet — golden tests or removal

## description

Review 1 #12 / Review 2 §4. The journal explicitly defers PPX, then the README later advertises ppx_effet as an optional package. The PPX shipped without the lab-first treatment that other surfaces received: no expansion audit for nested functions, local modules, lambdas, partial application, or generated code.

Two questions:
1. Is the explicit Effect.fn __POS__ __FUNCTION__ idiom annoying enough in real use to justify a PPX dependency? Write 20 real functions with the explicit form first, then judge.
2. Does ppx_effet's expansion handle the edge cases? Golden tests for nested functions, anonymous lambdas, partial application, top-level vs local bindings.

If (1) is no, remove ppx_effet from the README and keep only the explicit idiom. If (1) is yes but (2) shows expansion bugs, fix them before re-advertising.

## design

scratch/ppx_survival/ with two artefacts:
1. explicit_idiom_fixture.ml — 20 representative functions using Effect.fn __POS__ __FUNCTION__ body with realistic nesting, local modules, lambdas, partial application. Subjective judgement: does this read tolerably?
2. ppx_golden/ — golden tests for ppx_effet. Each .ml input pairs with a .expected.ml showing the expected expansion. Run via dune cram or a custom test runner.

Compare:
- explicit cost: how much repetition does the __POS__ __FUNCTION__ idiom add per call?
- ppx coverage: do nested functions get the right __FUNCTION__? Does an anonymous lambda inside a let get the surrounding binding's name? What happens with %effet.fn at module top-level?

If ppx coverage is incomplete, document the gaps and choose: ship the fixes, or remove the PPX from public docs.

## acceptance criteria

scratch/ppx_survival/ contains 20 realistic explicit-idiom functions and a golden-test suite for ppx_effet. journal.md gains a V-Pxv1..V-PxvN decision diary citing the subjective cost of explicit and the objective coverage of the PPX. Recommendation: (a) remove ppx_effet from README/public surface — use explicit only; (b) keep PPX but ship golden-test fixes for any expansion gaps — capture as bug-fix task; (c) keep PPX as currently shipped with documented gaps and the rationale that the gaps are tolerable. 1h time budget.
