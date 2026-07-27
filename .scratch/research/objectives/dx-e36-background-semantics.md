# Objective: DX-E36 — Background failure semantics: fail-fast vs supervised

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e36`
- Branch: `research/dx-e36-background-semantics` (already checked out here; do not create others)
- Phase: hardening wave (EOP audit §4.2) · Effort M · Risk med (cancellation/cause semantics) · **P0**
- Evidence IDs: `V-DX-E36-*` (orchestrator log); your journal is the branch record

## Executor profile

Concurrency-semantics design + implementation. The difficulty is not the
code volume (small) but the cancellation/cause precision: what exactly
happens when the background fails mid-`use`, what the body's finalizers
see, what the group cause looks like, and proving every branch of that
with deterministic tests. Similar discipline to E24/E28.

## Mission

Verified today: `with_background` runs the background as a supervisor
child and only observes its fate when `use` ends. A protocol reader or
heartbeat can die at second 1 while the body runs on for a minute —
structured lifetime, unstructured failure. The audit's fix is a
semantics split, and this experiment implements it.

## Read first (in order)

1. `AGENTS.md`.
2. `lib/eta/effect_supervisor_scope.ml` — current `with_background`
   implementation; `lib/eta/effect.mli` — its contract (says nothing
   about failure propagation).
3. `lib/eta/effect.mli` — `par`'s fail-fast contract (the model the
  fail-fast variant mirrors: first failure cancels siblings, cause
   propagates); `lib/eta/supervisor.mli` — `failures`/`check` (the
   supervised model that already exists).
4. `.scratch/research/eop-audit-2026-07-26.md` §4.2 (the claim you're
   implementing).
5. `test/core_common/supervisor_common_suites.ml` — current behavior
   tests you will migrate/extend.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Artifacts in `.scratch/research/dx/e36/` **on this branch** (commit
them): `journal.md`, `report.md`, `redteam/`.

## The experiment (decided upstream; precision is yours)

**The split.**

```ocaml
val with_background :
  ?name:string -> (unit, 'err) t -> (unit -> ('a, 'err) t) -> ('a, 'err) t
  (** FAIL-FAST. Run [background] while [use] executes. If [background]
      fails first, [use] is cancelled and the background's cause
      propagates (like {!par}'s sibling rule). If [use] finishes first,
      the background is cancelled and awaited (current behavior). *)

val with_supervised_background :
  ?name:string -> (unit, 'err) t -> (unit -> ('a, 'err) t) -> ('a, 'err) t
  (** SUPERVISED. Today's `with_background` semantics, verbatim:
      background failure is recorded in the supervisor (observable via
      [failures]/[check]), and [use] is unaffected until it ends. *)
```

- `with_best_effort_background` is **not** added — YAGNI
  (`with_supervised_background` + `ignore_errors` on the background).
  Kill it in your design notes with one sentence of evidence.
- `with_background`'s semantics change is breaking and batched per the
  idiom-pass discipline; the changelog notes it.

**Semantics to pin (each needs a named test):**
1. Background fails mid-`use` (typed failure) → body cancelled; group
   cause is the background's cause; body's finalizers run.
2. Background defects mid-`use` → same shape (defect propagates, not
   swallowed).
3. Body finishes first (success or failure) → background cancelled and
   awaited, current behavior unchanged.
4. Body interrupted mid-`use` → background cancelled; behavior matches
   `par`'s interruption shape.
5. `with_supervised_background` preserves every current behavior test
   verbatim (the semantics did not move).
6. Race: background fails in the same instant the body succeeds — one
   winner, no double-cancellation, documented which wins and why.

**Migration.** The 37 call-site lines: tests encoding current behavior
move to `with_supervised_background` mechanically;
`examples/background_lifecycle.ml` becomes the fail-fast teaching site.
Do NOT migrate http's daemon-based protocol readers (E42a territory) —
record the follow-up in your journal.

**Census/footguns.** +1 val; −1 footgun ("background death is invisible
to the body" removed by construction).

## Gates

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force
```

(The supervisor suites run on both substrates; jsoo included
deliberately.) Fix-forward ≤ 3 attempts per failure class, then BLOCKED.

## Protocol

1. **Seal your predictions** in `journal.md` (semantics of each edge
   above, migration split, census delta, review outcome) — commit before
   code (`docs(dx-e36): seal predictions`). Never edit after.
   (Dual-sealing: orchestrator's set is inherited on master; do not read
   it — fence below.)
2. **Docs-first**: the two `.mli` contracts before implementation. The
   fail-fast contract must say the cancellation/cause rule in ≤ ~8
   lines or the semantics is too complicated — if you can't, STOP and
   report.
3. Implement the smallest change satisfying the split.
4. Gates as above.
5. **Mechanical extras**: the six pinned tests; law-registry rows for
   the new law-bearing claims (AGENTS.md policy); migration diff;
   census/footgun deltas.
6. **Red-team pass** in `redteam/`: (a) write the OLD trap — a protocol
   reader dying mid-`use` — and show the new fail-fast catches what the
   old semantics missed (a test that would have hung/invisibly continued
   before); (b) try to make the supervised variant leak a failure into
   the body (it must not).
7. **Report**: contracts, semantics evidence per pinned edge, migration,
   census/footgun actuals vs. predictions (scored), red-team outcome,
   recommendation.

## Done means

- `E36 READY FOR REVIEW`
- `E36 BLOCKED: <reason>`
- `E36 STOP: <§4.6 stop condition>`

Orchestrator verifies and runs the adversarial review. Rework via
follow-ups.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E36's surface: the two combinators, their tests, their docs,
  the migration. No `daemon` changes, no http migration, no Supervisor
  redesign.
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e36/` must be committed.
