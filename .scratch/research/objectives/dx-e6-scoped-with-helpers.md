# Objective: DX-E6 — `Effect.Scoped.with_2` / `with_3` (kills `and@`)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e6`
- Branch: `research/dx-e6-scoped-with-helpers` (already checked out here; do not create others)
- Phase: B (hygiene) · Effort M · Risk low — **this experiment closes Phase B**
- Evidence IDs: `V-DX-E6-*` (orchestrator log); your journal is the branch record

## Executor profile

Small module, deep semantics. The implementation is ~40 lines of
composition over existing machinery (`with_scope`, `acquire_release`,
`par`), but the proof obligations are cancellation/finalizer semantics:
partial-acquire failure, reverse-order release, interrupt-during-acquire,
parity with nested brackets. You must prove these, not assert them. Second
deliverable is a docs recipe (the composition for arity > 3). The live
question is the pre-registered kill gate: does `with_3`'s labelled
boilerplate read worse than the ladder it replaces? Your review packet
decides.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Bootstrapping
N independent resources should have exactly one obvious spelling — not a
ladder of CPS inversion that also secretly serializes acquisition.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/eta/effect.mli` lifecycle cluster: `acquire_release`,
   `acquire_use_release[_exit]`, `with_resource[_exit]`, `with_scope`
   (lines ~469–540) — and their implementations. Note the E25 spelling:
   `with_scope`, not `scoped`.
3. `lib/eta/effect.mli` concurrency cluster: `par`, `all`, `map_par`
   (E24's final shape — function-first, `?max_concurrent`).
4. `docs/api-dx.md` resource section — you will extend it with the recipe.
5. `.scratch/research/dx/e23/report.md` for the report format bar.

## Method

Evidence-based-coding:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
The design is decided below; your proof obligations are the finalizer/
cancellation semantics and ladder parity. Working artifacts in
`.scratch/research/dx/e6/` **on this branch** (commit them): `journal.md`,
`report.md`, `redteam/`, `review/`.

## The experiment (one-pager, from DX-PRD-0001 §E6)

**Proposal.**

```ocaml
module Scoped : sig
  val with_2 :
    acquire1:('a, 'err) t -> release1:('a -> (unit, 'r1) t) ->
    acquire2:('b, 'err) t -> release2:('b -> (unit, 'r2) t) ->
    ('a -> 'b -> ('c, 'err) t) -> ('c, 'err) t
  val with_3 : (* same shape, three resources *)
end
```

Acquisition concurrent and fail-fast; a failed acquire leaves the scope to
release whatever was already registered; reverse-order release inherited
from the scope. Arity > 3 = hand-rolled recipe (progressive disclosure, not
an arity zoo).

**Semantics & edges.** Partial-acquire failure: registered releases still
run at scope exit — this is the core test. The recipe uses the `with_scope`
spelling (E25 landed). No optional arguments anywhere in this design (E24
erasure lesson does not apply).

**Gates from the one-pager.** Promote if inferred error rows stay readable
in review artifacts. **Kill the helpers (keep the recipe)** if `with_3`'s
labelled boilerplate rates worse than the ladder. **`and@` is killed by
this experiment's existence** — your evidence finalizes the parking-lot
entry.

## Protocol (predictions commit FIRST and separately)

1. **Seal your predictions** in `.scratch/research/dx/e6/journal.md`:
   expected teach-back answer ("second acquire fails — what happens?"),
   expected census/footgun deltas, two likeliest reviewer misreadings, and
   your honest prior on the kill gate (will `with_3` rate better or worse
   than the ladder?). Commit before any code change
   (`docs(dx-e6): seal predictions`). Never edit afterward.
2. **Docs-first.** Write the `module Scoped` `.mli` contracts and the
   `docs/api-dx.md` recipe section before implementing. The `with_2`
   contract must state: concurrency, fail-fast, partial-failure release,
   release order — within the ~10-line doc budget.
3. **Implement the smallest change.** Composition over
   `with_scope`/`acquire_release`/`par` — no new runtime machinery.
4. **Gates** (from the worktree, exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build test/js_jsoo
   ```
   (JS: E6 only adds a module; the mainline build proves the new code
   compiles under OCaml 5.4 for the JS track.)
   Fix-forward up to three attempts per failure class, then BLOCKED.
5. **Mechanical extras.**
   - **Semantics suite** (in `test/core_common/`, near the resource suites):
     partial-acquire failure (acquire1 ok, acquire2 fails → release1 runs,
     once); reverse-order release on success, typed failure, defect, and
     cancellation; interrupt-during-acquire behavior (state what it is,
     test it); parity with the nested `with_resource` ladder for the same
     program (exits, release order); release error rows `'r1`/`'r2` do not
     leak into the result type.
   - Census: lifecycle cluster before/after (orchestrator pre-count: 6 → 8
     vals, +1 concept). Verify independently. The justification line:
     replaces the `and@` operator (syntax machinery) with composition.
   - Footgun delta: expect −1/+0 (the serializing-ladder trap).
   - `docs/api-dx.md`: the recipe for arity > 3 (`with_scope` +
     `acquire_release` + `map_par`/`all`), with one worked example.
6. **Red-team pass.** Two probes, committed under
   `.scratch/research/dx/e6/redteam/` with verdicts:
   (a) leak attempt — write the program a careless reader would write
   expecting a failed second acquire to leak the first resource; show what
   actually happens; (b) the `and@` temptation — sketch (one comment block
   is enough) what composing two `with_resource` CPS functions would even
   mean, and record why the helper is the honest spelling instead.
7. **Review packet** in `.scratch/research/dx/e6/review/`, labeled (the
   orchestrator randomizes): one A/B pair —
   `boot-old.ml`/`boot-new.ml`: bootstrap three independent resources (a
   pool, a cache, a metrics sink — your choice of realistic shapes), old
   `let@` ladder vs `Scoped.with_3`. 15–35 lines each, self-contained.
   Plus `MANIFEST.md` and `QUESTIONS.md`: "second acquire fails — what
   happens?", "which runs first at scope exit?", "are acquisitions
   sequential?", and a screenshot-test prompt (nesting depth, distinct
   concepts visible).
8. **Report** in `.scratch/research/dx/e6/report.md`: gates summary,
   semantics-suite evidence, census/footgun vs. sealed predictions (scored
   explicitly), red-team outcome, deviations, and your promote/kill
   recommendation against the one-pager's gates — including your honest
   read on the kill gate BEFORE the review comes back.

## Done means

Your final message ends with exactly one of:

- `E6 READY FOR REVIEW`
- `E6 BLOCKED: <reason>`
- `E6 STOP: <§4.6 stop condition>`

The orchestrator verifies (diff, focused tests, evidence audit), runs the
independent review, and decides. Rework via follow-up messages.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E6 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E6's surface. Adjacent footguns → journal follow-ups.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e6/` must be committed.
