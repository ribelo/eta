---
id: Effet-9ey
title: "Research: typed request DSL over OCaml 5 native effects (R-D candidate,
  ungeneralised)"
status: open
priority: 3
issue_type: task
created_at: 2026-05-19T18:39:10.434Z
created_by: backlog
updated_at: 2026-05-19T18:46:26.261Z
dependencies:
  - issue_id: Effet-9ey
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:46:26.261Z
    created_by: backlog
---

# Research: typed request DSL over OCaml 5 native effects (R-D candidate, ungeneralised)

## description

Review 1 finding #4. R-D was rejected on the basis that OCaml 5's native effect handlers expose 'effc : 'c. 'c Effect.t -> ... option' — i.e. no static effect-row tracking — so a missing handler crashes at runtime. That is correct for raw native handlers in OCaml 5.4. The dismissal is too broad: the candidate set never tested a typed request DSL layered over native effects, where request witnesses carry static evidence that a handler is installed.

Hypothesis to lab:
type _ Req.t =
  | Db  : Db.t Req.t
  | Log : Log.t Req.t

val ask : 'svc Req.t -> ('env, 'err, 'svc) effet
val handle : handlers:'h -> ('env, 'err, 'a) effet -> ('env, 'err, 'a) effet

Where 'env tracks which Req constructors have installed handlers via a phantom presence set, and missing-handler is a compile error rather than runtime crash.

If this works, R-D returns to the table as a serious R-channel candidate. If it falls over, the rejection becomes evidence-backed for the typed-DSL-over-native-effects flavour, not just for raw native handlers.

## design

scratch/native_effects_research/ with two modules:
1. r_d_raw.ml — current rejection (raw Effect.Deep handlers, runtime-only check). Already proven to compile-and-crash; keep for comparison.
2. r_d_typed.ml — typed Req.t GADT plus phantom presence set on 'env. Build the smallest version that prevents compile-time of a program asking for an unhandled Req.

Negative test: try to compile 'let prog = Effet.ask Db' without a handle that supplies Db. Must fail with a useful error.

If the typed wrapper requires more boilerplate than env-row at every call site, the candidate falls on ergonomics. If it produces equally-clean syntax, R-D is genuinely competitive and the journal should record that V-R8/V-R10's dismissal was for the wrong reason.

## acceptance criteria

scratch/native_effects_research/r_d_typed.ml compiles. A negative test confirms a missing-handler program is a compile error. The lab compares ergonomics LOC with r_b_env_row.ml from scratch/r_research/. journal.md gains a V-RNv1..V-RNvN section with the per-variant verdict. Recommendation is one of: (a) R-D rejection holds as documented; (b) R-D rejection holds but for the right reason (ergonomics, not safety); (c) R-D returns to the candidate set — capture follow-up research. 2h time budget.
