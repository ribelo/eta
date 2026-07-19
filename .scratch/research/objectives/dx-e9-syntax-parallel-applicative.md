# Objective: DX-E9 — `Syntax.Parallel` vs. `Syntax.Applicative`

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e9`
- Branch: `research/dx-e9-syntax-parallel-applicative` (already checked out here; do not create others)
- Phase: C (syntax & PPX) · Effort M · Risk med · **live kill gate**
- Evidence IDs: `V-DX-E9-*` (orchestrator log); your journal is the branch record

## Executor profile

A small module split with a heavy evidential core. The diff is easy
(three modules, two call-site files); the weight is in honest law tests
and a well-built review packet that measures whether explicit `open`s
actually improve comprehension — because if they don't, this experiment
dies, and that's a good outcome too. Do not engineer for promote.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Today
`and*` means "fork fibers, cancel the sibling on failure" — and nothing
at the call site says so (T2). The `open` should be a declaration of
intent. But ceremony without measured comprehension gain is worse than
the status quo: the kill gate is real.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/eta/syntax.mli` + `syntax.ml` — current operators;
   `( and* ) = ( and+ ) = Effect.par`.
3. `lib/eta/effect.mli` `par` — the semantics `Parallel` keeps.
4. The two `and*` usage sites: `examples/background_lifecycle.ml`,
   `test/api_dx/api_dx_examples.ml`.
5. `docs/api-dx.md` — syntax guidance you'll rewrite.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Proof obligations: (a) both new modules obey their stated laws
(executable); (b) the review packet measures comprehension of the implicit
form vs. the explicit form WITHOUT leading the reviewer. Design snippets
that could convict either side — if the baseline is already obvious, the
packet must be able to show it.

Working artifacts in `.scratch/research/dx/e9/` **on this branch** (commit
them): `journal.md`, `report.md`, `redteam/`, `review/`.

## The experiment (one-pager, from DX-PRD-0001 §E9)

**Proposal.**

```ocaml
module Syntax : sig
  val ( let* ) : …  val ( let+ ) : …  val ( let@ ) : …
end
module Syntax.Parallel : sig
  val ( and* ) : …  val ( and+ ) : …  (* concurrent, fail-fast *)
end
module Syntax.Applicative : sig
  val ( and* ) : …  val ( and+ ) : …  (* sequential: left settles, then right *)
end
```

`Parallel` = today's `and*`/`and+` (`par`). `Applicative` =
`let* a = x in let+ b = y in (a, b)` — strict left-to-right, fail-fast by
sequencing, nothing forked. `and*`/`and+` are REMOVED from `Syntax` (the
migration forces the choice; compiler-guided, no shim).

**Gates from the one-pager.** *Promote* on a real comprehension delta
(explicit ≥ 80% accuracy, materially above baseline). *Kill* if baseline
is already ≥ 80% — the split is ceremony at that point.

## Protocol (predictions commit FIRST and separately; then step commits)

1. **Seal your predictions** in `.scratch/research/dx/e9/journal.md`:
   your guessed baseline accuracy, your guessed explicit accuracy, two
   likeliest reviewer misreadings per module. Commit before any code
   change (`docs(dx-e9): seal predictions`). Never edit afterward.
2. **Docs-first.** Write the `.mli` for all three modules before
   implementing. Each `and*` gets its semantics in ≤ 5 lines, including
   sibling fate on failure for `Parallel` and "nothing is forked" for
   `Applicative`. Add the "open exactly one" guidance — opening both
   shadows; state it.
3. **Implement the smallest change.** Split the module; migrate the two
   usage files to `Syntax.Parallel` (semantics preserved); update
   `docs/api-dx.md`.
4. **Gates** (exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo
   ```
   Fix-forward up to three attempts per failure class, then BLOCKED.
5. **Mechanical extras.**
   - Law tests: `Parallel` pair-order + fail-fast sibling cancellation
     (reuse existing par tests if they cover it — cite them); `Applicative`
     strict left-to-right (ordered side-effect log), zero fibers forked
     (observable: no sibling starts before left settles), fail-fast by
     sequencing, cancellation of an in-flight left on interrupt.
   - Distinctness probe: same program under each module observably differs
     (interleaved vs. ordered execution log) — committed under `redteam/`.
   - Census: syntax operators 5 → 7 vals (growth — restate the §3.1
     justification in your journal), modules +2. Footguns: expect −1/+0
     with the "open exactly one" note.
6. **Red-team pass.** Write the bug the OLD shape invited: an `and*` the
   author believed was sequential (e.g. two order-sensitive DB writes)
   — under the old always-open `Syntax` it silently races. Show that under
   the new shape the author's `open` declares the semantics, and that the
   `Applicative` version is sequentially correct. Commit under `redteam/`
   with a verdict.
7. **Review packet** in `.scratch/research/dx/e9/review/`, labeled (the
   orchestrator blinds it):
   - `implicit.ml`: a realistic program using today's always-open
     `let open Syntax in let* … and* …` (baseline).
   - `explicit-par.ml`: the same program with `open Syntax` +
     `open Syntax.Parallel`.
   - `explicit-app.ml`: a program that WANTS sequencing (order-sensitive
     writes) with `open Syntax` + `open Syntax.Applicative` — and its
     wrong-under-old-shape twin `implicit-race.ml` (the red-team artifact
     works double duty).
   - `MANIFEST.md`, `QUESTIONS.md`: "how many fibers fork in snippet X?",
   "what happens to `b` when `a` fails?", "does the order of effects
   matter in snippet Y — and is it guaranteed?"
8. **Report** in `.scratch/research/dx/e9/report.md`: gates summary, law
   test evidence, census/footgun actuals vs. sealed predictions, red-team
   outcome, deviations, and your promote/hold/kill recommendation —
   evaluated against the one-pager's gates HONESTLY, including the
   possibility that the baseline is fine.

## Done means

Your final message ends with exactly one of:

- `E9 READY FOR REVIEW`
- `E9 BLOCKED: <reason>`
- `E9 STOP: <§4.6 stop condition>`

The orchestrator verifies, runs the independent review (baseline and
explicit snippets measured separately, blinded), and decides — the kill
gate will be evaluated strictly on the review numbers.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E9 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E9's surface: `lib/eta/syntax.*`, the two usage files,
  `docs/api-dx.md`, syntax tests. Do not touch `Effect.par` itself.
  Adjacent footguns → journal follow-ups.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e9/` must be committed.
