---
id: Effet-0uk
title: "Research: R-channel DX at scale (V-R10 stress test on a 20-module
  synthetic app)"
status: closed
priority: 2
issue_type: task
created_at: 2026-05-19T18:38:37.814Z
created_by: backlog
updated_at: 2026-05-20T00:35:37.383Z
closed_at: 2026-05-20T00:35:37.383Z
close_reason: "Completed. Three labs executed: (1) scratch/r_dx_research/
  20-module synthetic app comparing env-row/args/bag at three levels; (2)
  scratch/r_followup_research/ black-box effects, public .mli styles, naming
  collisions, library evolution; (3) scratch/ppx_env_research/ with
  [%effet.sync]/[%effet.async]/[%effet.env] implemented. Decision diaries
  V-Dxv1–V-Dxv6, V-RFv1–V-RFv6, V-PPX1–V-PPX6 recorded in journal.md lines
  5270+. V-R10 confirmed at scale with DX mitigations. PPX helpers shipped in
  ppx_effet."
dependencies:
  - issue_id: Effet-0uk
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:46:21.703Z
    created_by: backlog
---

# Research: R-channel DX at scale (V-R10 stress test on a 20-module synthetic app)

## description

Review 1 finding #3. The R-channel auto-DI lab proved object-row env satisfies one specific criterion ('A's body mentions zero services'), but did not measure error-message quality, compile-time performance, hover usefulness, or large-codebase maintainability — all of which the journal's own R-channel reasoning earlier identified as object-row weaknesses.

V-R10's claim is overfitted to a 3-function example. Real-world impact is unknown.

Generate a synthetic 20-module app: 30 capability methods spread across modules, deep bind chains (4–8 levels), intentional method-name collisions on common verbs (query, get, run, fetch), and one 'service whose method shape changed' refactor. Measure:
- inferred row size in the deepest function's signature
- compiler error message length and pinpoint quality on a missing capability
- hover output / merlin-typed-hole usefulness in editors
- dune build wall-clock time
- recompilation cost of changing one capability method's type

## design

scratch/r_dx_research/ with a generator script and a 20-module fixture. Each module exports 1–2 service-using effects that the next layer composes. Final layer has a row of ~15+ methods.

Three measurements per fixture state:
1. Build time (clean and incremental, with merlin/lsp index off and on)
2. Error message text and length on intentionally-broken boot env
3. ocamlfind ocamlc -i output size at the top of the dependency chain

Comparison points:
- argument-passing baseline: same fixture rewritten with explicit ~service args
- composite-bag baseline: one 'services' object threaded as a value parameter
- env-row current: as today

The lab is descriptive, not prescriptive — its job is to measure DX cost, not to recommend a flip. But if env-row's compile time or error-message quality is materially worse than the alternatives at scale, V-R10 must be reopened.

## acceptance criteria

scratch/r_dx_research/ contains a 20-module synthetic app at three rewrite levels (env-row, args, composite). Build-time and error-message measurements are recorded for each. journal.md gains a V-Dxv1..V-DxvN section presenting the data without spin. Recommendation is one of: (a) V-R10 confirmed at scale; (b) V-R10 holds for type soundness but env-row introduces unacceptable DX cost — capture mitigation tasks; (c) flip to args or composite — capture migration epic. 2h time budget.
