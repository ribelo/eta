# Follow-up 1: DX-E15 — KILL REJECTED; resume with the verified construction

Your kill was premature — and your rigor was not the problem. The restore
primitive exists but lives in Eio's hidden implementation, invisible from
the public API docs. Independent review found it; the orchestrator
reproduced it. E15 resumes on this evidence.

## The evidence (verified independently, twice)

`Eio__core__Switch.run_in : t -> (unit -> unit) -> unit` moves the
CURRENT fiber into a target switch's cancellation context, runs the
callback, and moves it back. Source: `lib_eio/core/switch.ml` (`run_in`),
`lib_eio/core/cancel.ml` (`move_fiber_to`, `protect`).

Construction (mask-entry switch):

```text
C  exact current parent context
└─ R  mask-entry switch, created at uninterruptible entry, BEFORE protect
   └─ P  protected context (Cancel.protect's child)
```

- `uninterruptible`: create `R` under `C`, then `Cancel.protect` → `P`.
- `interruptible e`: `run_in R (fun () -> eval e)` — the fiber runs in
  `R`'s context: cancellation propagates `C → R` and wakes blocked
  operations (accept, sleep, promise, flow I/O); it stops at `P`.
- The SAME fiber moves (no fork): `current_fiber_id` and fiber-reentrant
  protocols (Signal lane ownership, tracing) are unaffected — the fork
  relay's fatal flaw, avoided.

Orchestrator's independent probe (`.scratch/runin-probe/probe.ml` in this
worktree — keep or absorb into your committed probes):
`restore-during-block: DELIVERED` (a blocked wait inside `run_in` was
woken by `R`'s cancellation); `restore-pending-entry: RAISED` (pending
cancellation raises at entry — no lost wakeup); exiting the mask-entry
`Switch.run` re-reports the error at the switch boundary (normal Eio
switch error semantics — your wrapper must account for it, and preserve
exceptions/backtraces around `run_in` since it returns `unit`; the
`result := Some (Ok/Error)` pattern works).

## The decisions (orchestrator, with the reviewer)

1. **Ship against the internal, isolated and honest.** ONE
   backend-internal module is the only place that mentions
   `Eio__core__Switch`; everything else consumes the Eta contract's new
   mask operation. Document in that module and the journal: internal
   API, may change across Eio versions; Eio version pinned by the repo
   already; upstream-exposure follow-up registered (the human files the
   Eio issue — external systems are out of programme scope).
2. **Contract shape** (reviewer's sketch, yours to finalize):
   `uninterruptible` installs a restore into a dynamic binding (the E19
   `local_with_binding` machinery is the substrate); `interruptible`
   reads it — identity outside a mask; nested `uninterruptible` installs
   a new restore and wins; inside a restored region, repeated
   `interruptible` is identity.
3. **Finalizers: restoration forbidden** (both predictions confirmed):
   finalizer execution binds a "restoration forbidden" marker before its
   existing `protect`; a restore inherited from an enclosing
   `uninterruptible` must not escape finalizer protection.
4. **jsoo:** depth save / set-0 / restore-with-`Fun.protect`, plus
   boundary `check_cancel` at entry and at successful exit (the pending
   case must raise at both edges; the "protected sub not seeded" probe
   result is irrelevant here — depth restoration creates no child
   context and keeps the same `fiber_cancel`).
5. **Corrected precision for the journal** (append-only): the kill
   report overclaimed — "no restore" is false for Eio's hidden
   implementation; "every synthetic sub-context must be redesigned" is
   false; "private-context move unavailable" is false for hidden
   modules. Record the corrections explicitly; the Phase 0 probe results
   themselves stand (they killed the WRONG construction, not the right
   one).

## What resumes (from the original objective)

Everything in Phase 1/2, now against the verified model:

- Docs-first: the `.mli` contract (≤ ~12 lines) + the checkpoint list
  (already landed — keep) + the finalizer answer.
- Implementation: the contract mask operation per backend (native:
  mask-entry switch + `run_in`; jsoo: depth save/restore with boundary
  checks), the dynamic restore binding, the finalizer marker.
- Laws (E22 registration): mask-stack laws
  (`uninterruptible (interruptible (uninterruptible e))` ≡
  `uninterruptible e`; innermost-wins); delivery at most once; no lost
  wakeup when cancel races mask entry — BOTH backends.
- Race corpus: cancel-during-mask-entry, cancel-at-checkpoint, nested
  masks, cancel-between-restore-and-exit, cancel-before-restore-entry
  (the pending-entry raise), cancel-during-restored-block.
- Red-team: every lost-wakeup construction against the REAL model;
  fork-identity preservation (Signal lane) test.
- Review packet: the accept-loop victim against the combinator.
- Gates: full set both shells (`_build-mainline` for mainline).

## Records

Journal: the kill-rejection entry (corrections + the verified model +
your design). Report: rewritten for the resumed experiment. Prediction
scoring now includes the killed-then-resumed history honestly.

## Done means

`E15 READY FOR REVIEW` / `E15 BLOCKED: <reason>` / `E15 STOP: <§4.6>`.
(A second kill is also reportable — but only against the run_in model,
with the same precision you brought the first time.)

## Scope fence

Same as the original objective, plus: `Eio__core__Switch` appears ONLY
in the one backend-internal module you designate; anywhere else it
appears is a scope violation.
