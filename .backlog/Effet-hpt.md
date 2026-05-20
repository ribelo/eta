---
id: Effet-hpt
title: "Survival lab: collapse Sync and Async into a single leaf"
status: open
priority: 3
issue_type: task
created_at: 2026-05-19T18:41:20.424Z
created_by: backlog
updated_at: 2026-05-19T18:47:01.953Z
dependencies:
  - issue_id: Effet-hpt
    depends_on_id: Effet-0jv
    type: parent-child
    created_at: 2026-05-19T18:47:01.953Z
    created_by: backlog
---

# Survival lab: collapse Sync and Async into a single leaf

## description

Review 2 §6 / Review 1 audit. Effect.t has two near-identical leaves: Sync (string * (env -> 'a)) and Async (string * (env -> 'a)). The journal does not record a semantic difference between them at runtime — both are interpreted by the same Sync/Async case which calls f env. If they are observably identical, having two constructors is needless API width.

Survival test: collapse to a single Effect.eval (or Effect.sync) leaf. Reintroduce Async only if a test proves different cancellation, scheduling, tracing, or blocking semantics that the unified leaf cannot express.

Risk: this is a small public-API change. apps using Effect.async by name need migration. If collapsed, ship the rename via a deprecated alias for one minor version.

## design

Branch A: keep current Sync + Async distinction.
Branch B: delete Async constructor; rewrite all internal use of Async to Sync; deprecate the public Effect.async alias.

Run the full test suite (56+ tests including observability, cancellation, race, retry, timeout) on Branch B. If anything breaks, identify the semantic difference and document it as the reason to keep Async. If nothing breaks, the constructor is decorative.

Special attention:
- auto-instrumentation: Sync and Async leaves both get spans when auto_instrument:true; check whether the source-of-truth name carries.
- Eio interaction: confirm there is no place where Async assumes blocking IO behaviour that Sync does not.
- documentation: README and effect.mli currently distinguish them; collapse should update both.

If a real difference surfaces (e.g. Async should yield the fiber explicitly via Eio.Fiber.yield), that becomes an explicit semantic split: rename to Sync and Yield_then_sync, or keep both with documented difference.

## acceptance criteria

scratch/sync_async_survival/ contains the collapsed branch. All 56+ existing tests pass on Branch B with the deprecation alias in place, or the test failures are documented and explain why the constructors must stay separate. journal.md gains a V-SAv1..V-SAvN decision diary. Recommendation: (a) collapse — capture as small migration task with deprecation; (b) keep separate with newly-documented semantic difference; (c) collapse with a different name to capture the actual difference. 1h time budget.
