---
id: Effet-na0
title: "Measurement: compile-time perf and type-error quality at scale"
status: open
priority: 3
issue_type: task
created_at: 2026-05-19T18:44:36.117Z
created_by: backlog
updated_at: 2026-05-19T18:48:26.518Z
dependencies:
  - issue_id: Effet-na0
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:48:26.518Z
    created_by: backlog
---

# Measurement: compile-time perf and type-error quality at scale

## description

Review 1 OCaml-blind-spots #6. Effet leans heavily on GADTs, polymorphic variants, and object rows. Toy examples compile fast and produce readable errors. Real codebases with deep binds, large inferred rows, and cross-module GADT inference may not.

Scope: a measurement task, not a research session. Build a representative real-world workload, run dune build with timing, capture diagnostics on intentional errors. Establish whether Effet's type machinery scales, and where it breaks if it does.

This is not redundant with Effet-0uk (R-channel DX at scale): that task focuses on env-row vs alternatives. This task focuses on raw type-checker performance and error verbosity for a chosen-and-fixed env-row design.

## design

scratch/typecheck_perf/ with:
1. A 50-module synthetic app using all Effet primitives heavily: Effect.bind chains 10+ levels deep, par/all over heterogeneous effect lists, race + retry + timeout combinations, polymorphic-variant typed errors with 5+ row entries.
2. A small benchmark script that runs dune build clean and incremental, measures wall time, and captures peak memory.
3. A diagnostic-quality script that injects single-error mutations at random sites and captures the resulting compiler error length and pinpoint quality.

Output: a markdown report in the scratch dir with the measurements, plus a journal section interpreting them. If anything concerning surfaces (multi-second build times, error messages over 200 lines, cryptic GADT-rejection errors), capture as follow-up tasks.

## acceptance criteria

scratch/typecheck_perf/ contains the 50-module synthetic app, build-time and error-quality benchmarks. A markdown report records the measurements. journal.md gains a V-CTv entry summarising the findings. If problems surface, follow-up tasks are captured. 2h time budget.
