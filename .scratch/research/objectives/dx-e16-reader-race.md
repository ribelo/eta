# Objective: DX-E16 — `Reader`: a validation race for the no-`R` decision

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e16`
- Branch: `research/dx-e16-reader-race` (already checked out here; do not create others)
- Phase: E (research) · Effort S · Risk low (core untouched by construction) · **expected kill — designed to be lost cleanly**
- Evidence IDs: `V-DX-E16-*` (orchestrator log); your journal is the branch record

## Executor profile

Build the rival in its strongest form, then judge it fairly. The failure
mode of this experiment is a rigged race: a strawman `Reader` that
confirms the no-`R` boundary by being badly written. The
evidence-based-coding skill is explicit: steelman before testing. The
Reader port must be the version a competent FP developer would defend —
or the evidence is worthless.

## Mission

Eta bets that value-passing beats an environment parameter — defended by
reasoning and ZIO's HList scars, never by an in-repo comparison. The
honest defence is to build the rival and race it. Either the no-`R`
boundary gains evidence, or it was wrong and we find out now, cheaply.

## Read first (in order)

1. `AGENTS.md`.
2. `docs/zio-boundaries.md` — the no-`R` decision and its stated reasons.
3. One `examples/` service with real dependency shape (you choose;
   `examples/connection_pool.ml`, `examples/cached_resource.ml`, or a
   better one you find — justify the choice by dependency count).
4. `.scratch/research/dx/e19/report.md` — the scoped-capability decision
   (how Eta consciously handles the *runtime-service* slice of env-like
   needs, so the race measures the application-dependency slice only).

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Artifacts in `.scratch/research/dx/e16/` **on this branch** (commit
them): `journal.md`, `race/` (both ports + the Reader module),
`report.md`.

## The experiment

**Step 1 — Build the rival (~50 lines, optional module, core untouched).**

```ocaml
module Reader : sig
  type ('env, 'a, 'err) t = 'env -> ('a, 'err) Effect.t
  val ask   : ('env, 'env, 'err) t
  val local : ('env -> 'env) -> ('env, 'a, 'err) t -> ('env, 'a, 'err) t
  val map   : ('a -> 'b) -> ('env, 'a, 'err) t -> ('env, 'b, 'err) t
  val bind  : ('a -> ('env, 'b, 'err) t) -> ('env, 'a, 'err) t -> ('env, 'b, 'err) t
end
```

**Step 2 — The race.** Port one real `examples/` service twice:
value-passing (current style) vs. `Reader`. Same behavior, both compile,
both run under the test gates. Justify the service choice.

**Step 3 — Measure against the pre-registered criteria** (each scored,
with the raw artifact quoted):
1. Diff size and shape (lines, and WHAT the extra lines are).
2. Inferred types on hover — paste the inferred signatures of the main
   service function in both ports (from `dune describe` or merlin/ocamlc
   `-i`).
3. Error messages on a deliberately wrong env record — paste the actual
   compiler error for both ports.
4. Env-blob drift check: the env record's field count in the Reader
   port, and — the decisive test — add a 4th dependency to both ports
   and measure what changes (record type + construction sites vs. one
   function signature).
5. Reviewer comprehension: the orchestrator runs this; prepare both
   ports as clean, self-contained files for review.

**Steelman requirement.** Your journal must show the Reader port was
written in its strongest form: name the two strongest arguments FOR
Reader you can construct, and show the port gives them their best
chance. If the race looks rigged toward value-passing, it will be
re-run — that is the one way this experiment fails instead of closing.

**Gates.** *Promote* as an optional package only if Reader wins on the
pre-registered criteria (majority of 1–4 plus the review). *Kill* —
expected — with the diff and ratings as `V-DX-E16`'s evidence: the
no-`R` boundary then rests on in-repo evidence, not taste.

## Protocol

1. **Seal your predictions** in `journal.md` (each criterion's outcome,
   the final verdict, your strongest two pro-Reader arguments) — commit
   before code (`docs(dx-e16): seal predictions`). Never edit after.
   (Dual-sealing: orchestrator's set is inherited on master; do not read
   it.)
2. **Docs-first** for the Reader module (its `.mli` comments, on the
   branch — it never touches core mli files).
3. Build, race, measure — in that order.
4. **Gates** (exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   ```
   Both ports must compile and any tests you add must pass.
5. **Red-team pass:** attack the Reader port's strongest point — if its
   best argument is "no parameter threading", show what `local` costs
   when a subtree needs a modified env (the honesty check).
6. **Report:** both ports inline, the four measurements with raw
   artifacts, the steelman section, hypothesis ledger (promote/kill),
   prediction scoring, recommendation.

## Done means

- `E16 READY FOR REVIEW`
- `E16 BLOCKED: <reason>`
- `E16 STOP: <§4.6 stop condition>`

Orchestrator runs the comprehension review and decides. Rework via
follow-ups (including a re-run if the race looks rigged).

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md`, `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- The Reader module lives ONLY under `.scratch/research/dx/e16/race/`
  (with its own dune-project if needed) — it must not appear in any
  package's install surface. Core mli/ml untouched.
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e16/` must be committed.
