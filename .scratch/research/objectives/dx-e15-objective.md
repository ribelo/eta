# Objective: DX-E15 — `Effect.interruptible`: restoring cancellation inside masks

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e15`
- Branch: `research/dx-e15-interruptible` (already checked out here; do not create others)
- Phase: E · Effort M · Risk **high** (cancellation semantics) · kill is a first-class outcome
- Evidence IDs: `V-DX-E15-*` (orchestrator log); your journal is the branch record

## Executor profile

The hardest cancellation assignment in the programme. You must FIRST
establish what both backends actually do (executable semantic probes —
Eio's `Cancel.protect`/`Cancel.sub` interaction, jsoo's
`fiber_protect_depth` composition) BEFORE designing anything, then design
a mask model whose laws hold on both substrates, then prove them. The
kill gate is real and honorable: if the semantics can't be stated within
the doc budget or implemented cleanly on both backends, you kill it and
the checkpoint-list documentation still lands as the DX win. Strong
cancellation algebra; zero tolerance for wishful semantics.

## Mission

Eta may be complicated inside; using Eta must feel beautiful.
`uninterruptible` is one-way today; a masked region that must block
*interruptibly* (an accept loop, a cleanup that awaits) is inexpressible
without dodging the mask. Restore — if it can be honest on both
backends.

## Read first (in order)

1. `AGENTS.md` — Nix-only gates, break loudly. **E22 policy: laws need
   named tests.**
2. The E15 one-pager below — the contract.
3. `lib/eta/effect_core.ml` — `uninterruptible` (=
   `contract.protect (fun () -> eval frame eff)`) and the E13 `async`
   leaf (uses `cancel_sub` + `protect` together — the closest existing
   machinery to a restore).
4. `lib/eta/runtime_contract.mli` — the cancellation surface: `protect`,
   `cancel_sub`, `cancel`, `await_cancel`, `cancellation_reason`, and
   the same-domain resume rules.
5. `lib/jsoo/eta_jsoo.ml` — `fiber_protect_depth` composition (delivery
   condition: `cancel_reason <> None && protect_depth = 0`).
6. Eio's `Cancel` documentation (in the switch: `_opam` or the Nix
   store) — `protect`, `sub`, propagation semantics between parent and
   sub-contexts.
7. `.scratch/research/dx/e13/report.md` — how `cancel_sub` behaves
   (E13's synthetic-interruption construction).

## The experiment (one-pager, from DX-PRD-0001 §E15)

**Proposal.**

```ocaml
val interruptible : ('a, 'err) t -> ('a, 'err) t
(** Re-enable parent cancellation within a dynamically enclosing
    [uninterruptible]. Masks stack; interruption is delivered at the first
    interruptible point. Outside any mask: identity. *)
```

**Semantics & edges (the substance).**
- Cancellation checkpoints (`yield`, `sleep`, blocking awaits) must
  become documented API — today implicit. The experiment forces the
  checkpoint list into docs: a DX win even if the combinator dies.
- `interruptible` inside a finalizer: decide explicitly (ZIO says no);
  record Eta's answer and its reason.
- Mask-stack laws: `uninterruptible (interruptible (uninterruptible e))`
  ≡ `uninterruptible e`; delivery at most once; no lost wakeup when
  cancel races mask entry — property-tested against both backends.

**Gates.** Promote only with the checkpoint list published and laws green
on both substrates. Kill if the semantics cannot be stated within the doc
budget — inexpressible-in-docs cancellation is worse than none.

## Protocol

### Phase 0 — establish substrate truth (before any design)

Executable probes, committed under `.scratch/research/dx/e15/probes/`:

1. **Native (Eio):** inside `Cancel.protect`, create a `Cancel.sub`
   context and block on it unprotected. Does parent cancellation deliver
   into the sub? Does protect cover the sub? Does delivery-on-sub escape
   the outer protect? Document the exact propagation/protection matrix —
   this determines whether restore is implementable natively without new
   contract machinery.
2. **jsoo:** confirm the depth-counter composition (nested protect;
   delivery only at depth 0; what happens to a pending cancellation
   when depth returns to 0 — delivered at the next checkpoint?).
3. **Checkpoint inventory (both backends):** enumerate where
   cancellation is actually delivered today (`yield`, `sleep`,
   `await_promise`, channel/queue/semaphore waits, `Effect.async` park,
   blocking service awaits). This becomes the documented checkpoint
   list — REQUIRED DELIVERABLE EVEN ON KILL.

### Phase 1 — the mask model (if Phase 0 admits it)

1. **Seal your predictions FIRST** in
   `.scratch/research/dx/e15/journal.md` (before ANY code, including
   Phase 0 probes — commit `docs(dx-e15): seal predictions` as your
   first commit).
2. Design the mask model per backend: the mapping of `interruptible`/
   `uninterruptible` nesting to the backend mechanism; the mask-stack
   laws; delivery-at-most-once; no-lost-wakeup-on-mask-entry.
3. Docs-first: the `.mli` contract (≤ ~12 lines) + the checkpoint list
   in `docs/api-dx.md` + the finalizer answer with its reason
   (orchestrator's sealed prediction: NO — finalizers run under
   protection; restoring invites re-entrant cancellation of cleanup;
   verify or refute).
4. Implement the smallest change. If the native side needs new contract
   machinery, cost it against the doc budget — if the semantics can't
   stay simple, that is the kill signal, honestly reported.
5. **Gates:**
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build --build-dir=_build-mainline @install
   nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws test/js_jsoo test/cache_jsoo test/signal_jsoo --force
   ```

### Phase 2 — laws and adversarial proof

1. **Properties** (E22 registration): mask-stack laws
   (`uninterruptible (interruptible (uninterruptible e))` ≡
   `uninterruptible e`; nested-mask innermost-wins); delivery at most
   once; no lost wakeup when cancel races mask entry — on BOTH backends.
2. **Race corpus** (named tests): cancel-during-mask-entry,
   cancel-at-checkpoint, nested masks, cancel-between-restore-and-exit.
3. **Red-team:** lose a cancellation deliberately in every construction
   you can think of; each either refuses (prove) or is documented
   verbatim in the journal as a finding (kill input).
4. **Review packet:** a real uninterruptible accept loop whose blocking
   accept is wrapped in `interruptible` (the canonical victim), written
   against the new combinator, + the mask-model section of
   `docs/api-dx.md`, + `QUESTIONS.md` ("inside `uninterruptible`, when
   can this fiber be cancelled?").

## Kill criteria (honored exactly)

- The semantics cannot be stated within the doc budget (~12 mli lines +
  the checkpoint list).
- The native substrate requires contract machinery that makes the model
  unspeakable-simply, OR the two backends cannot share one stated mask
  model.
- Any lost-wakeup construction you cannot eliminate.

On kill: the checkpoint-list documentation + Phase 0 probe records STILL
land (those are the DX win); the journal records why restore is
inexpressible; the parking lot gets the entry.

## Report

`report.md`: Phase 0 substrate truth (probe outputs), the mask model,
the finalizer answer, laws with property names per backend, the race
corpus, red-team outcomes, census/footgun deltas, prediction scoring,
promote/hold/kill recommendation against the one-pager's gates.

## Done means

- `E15 READY FOR REVIEW` / `E15 BLOCKED: <reason>` / `E15 STOP: <§4.6>`
- On kill: `E15 KILLED: <the precise inexpressibility>` is also a
  complete, honorable signal.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`,
  `docs/research/`, `.scratch/research/dx-prd-0001.md` beyond §E15
  quoted above, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- No other cancellation-model changes (do not touch `uninterruptible`'s
  own semantics, the async leaf, or the contract's cancellation surface
  beyond what the mask model strictly requires — any such need is a
  BLOCKED signal, not an improvisation).
- Stay in E15's surface. Adjacent discoveries → journal follow-ups.
- Everything under `.scratch/research/dx/e15/` must be committed;
  `objective.md` stays uncommitted.
