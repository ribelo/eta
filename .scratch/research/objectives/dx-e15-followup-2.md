# Follow-up 2: DX-E15 — fork-semantics findings (INCORRECT verdict)

The implementation review reproduced a deadlock and two divergences. All
three share one root: the restore binding is fork-INHERITED, but a restore
closure is valid only for the fiber that owns the mask. Fix the model, not
the symptoms.

## Findings (verified by the reviewer with reproductions)

1. **CRITICAL — `interruptible` in a forked child deadlocks fail-fast.**
   `uninterruptible (par (interruptible Effect.never) (Effect.fail `Boom))`
   times out instead of returning `Fail Boom`: the child inherits the
   restore, `run_in` moves it from its own context `Q` into the mask-entry
   context `R`, the sibling's failure cancels `Q`, and the child — waiting
   in `R` — never wakes. Backend divergence too (jsoo retains `Q`).
2. **HIGH — jsoo children start at `fiber_protect_depth = 0`.** A child
   forked inside `uninterruptible` is born UNmasked (native children stay
   behind the protected barrier). The backends disagree on whether masks
   cover children.
3. **HIGH — restoration state outlives the mask through daemons.** A
   daemon forked under a mask retains `Restore restore_switch` after the
   switch is finished (later `interruptible` raises "Switch finished"
   instead of identity); a daemon forked during cleanup retains
   `Restoration_forbidden`, wrongly disabling restoration in its later
   independent masks.
4. **MEDIUM — the suite omits the invalidating constructions** (no
   fork-under-mask, sibling-failure, daemon-outliving cases; the
   duplicate-cancel test is sequential on one idempotent handle).

## The model fix (orchestrator's direction — verify, don't assume)

**Mask bindings become fiber-local, NOT fork-inherited.** The mask model
converges on one sentence: *masks cover children; restoration is
fiber-local.* Concretely:

- `uninterruptible` masks the calling fiber's dynamic extent; children
  forked inside are masked via context lineage (native: `Q` descends from
  the protected context; jsoo: the child inherits the parent's
  `fiber_protect_depth` — FIX the fork to propagate it).
- The `Restore`/`Restored`/`Restoration_forbidden` bindings do NOT
  inherit at fork. A forked child calling `interruptible` sees no
  restore → identity → stays masked (exactly today's pre-combinator
  behavior: safe, no deadlock, fail-fast preserved).
- Daemons inherit neither binding: daemon work is independent; its later
  masks behave normally.
- The mli gains one sentence: restoration is fiber-local; children
  forked inside a mask remain masked.
- If `local_with_binding` has no non-inheriting variant, add the minimal
  fiber-local binding kind at the contract level — do not thread special
  cases through E19's sites.
- A future "child-restore" (listening to BOTH parent-cancellation `R`
  and sibling fail-fast `Q`) is explicitly OUT of scope — register it as
  a follow-up with the multi-context-observation problem stated.

## Tests required (the reviewer's constructions become regression tests)

- The critical repro: `uninterruptible (par (interruptible never)
  (fail Boom))` returns `Fail Boom` promptly on BOTH backends; the child
  is interrupted via `Q`, fail-fast intact.
- Mask-covers-children: a child forked inside `uninterruptible` is NOT
  interruptible-by-default on both backends (jsoo depth propagated).
- Daemon independence: daemon forked under a mask → later
  `interruptible` is identity (no "Switch finished"); daemon forked in
  cleanup → its later masks restore normally.
- Duplicate-cancel with COMPETING sources (not sequential calls on one
  idempotent handle): delivery at most once.
- All previous laws/races stay green.

## Records and gates

Journal: append-only entry — the fork-inheritance design error, the
fiber-local model, and the semantic statement (one sentence, above).
Report: updated model section; the reviewer's reproductions cited. mli:
the fiber-local sentence. Gates: full set both shells
(`_build-mainline` for mainline).

## Done means

`E15 READY FOR REVIEW` / `E15 BLOCKED: <reason>` / `E15 STOP: <§4.6>`.
Same scope fence (`Eio__core__Switch` stays in `eta_eio_mask.ml` only).
This file stays uncommitted.
