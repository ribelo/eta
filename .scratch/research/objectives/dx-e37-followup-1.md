# Follow-up 1: DX-E37 — evidence truth rework (mechanism cleared; evidence isn't)

The review's concurrency audit found the staging/commit mechanism SOUND
(no leak, no double-release, safe commit window, correct ordering). The
blocker is evidence and registry truth. `objective.md` still applies.

## Y1 (blocking) — the three discriminating tests that must exist

1. **Parent interruption during acquisition**: cancel the batch from the
   PARENT while acquisitions are in flight (not a sibling failure —
   R149's current proxy). Assert reverse-order rollback of completed
   acquisitions and exactly-once finalization.
2. **Rollback release failure**: an acquisition fails (or the batch is
   cancelled) and a STAGED release itself fails during rollback. Assert
   the diagnostics are preserved and correctly shaped (not dropped, not
   mis-categorized) per existing finalizer cause semantics.
3. **Acquire defect rollback**: an acquire raises (defect, not typed
   failure) mid-batch. Assert rollback order and the defect's
   propagation shape.

## Y2 (blocking) — registry truth repair (LAWS.md)

- R149: re-point at Y1's true parent-interruption test.
- R153: re-point at Y1's rollback-release-failure test, or narrow the
  claim to post-commit owner finalizers explicitly.
- R84: remove/replace the stale references to the deleted recipe tests
  and the removed "parallel ownership bridge" claim.
- Refresh every exact span invalidated by the 13-line mli insertion
  (M112, R102–R106, and any neighbor pointing at pre-insertion lines).
- Fix the header/totals arithmetic (cluster count vs. covered totals)
  to match the actual rows.
- Sweep the whole file for other stale pointers while you're at it —
  one bad-pointer class per fix, not one per discovery.

## Y3 (blocking) — jsoo coverage

Register `acquire_all_par` tests on the jsoo suite (the `check`/`yield`
placement is backend-sensitive): at minimum success-transfer order,
sibling-failure rollback, and parent interruption. Same discriminators
as native where the substrate allows.

## Y4 — api-dx heterogeneous note

`docs/api-dx.md:498-503` currently recommends an "explicit
owner-registration bridge" — that's the OLD non-transactional mechanism
this experiment obsoleted. Fix to: any concurrent heterogeneous bridge
must also stage and atomically transfer (or simply recommend the
sequential ladder for the heterogeneous case). One paragraph, honest.

## Protocol

Journal note (micro-predictions), implement, re-run native trio +
mainline js_jsoo, update report (evidence claims re-stated to match the
tests that exist), registry updated, usual signal. Same scope fence.
This file stays uncommitted.
