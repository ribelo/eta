# Objective: DX-E10 — Function-level `let%eta` / `[@@eta.trace]` (hold-default)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e10`
- Branch: `research/dx-e10-function-sugar` (already checked out here; do not create others)
- Phase: C (syntax & PPX) · Effort M · Risk med · **default state: HOLD**
- Evidence IDs: `V-DX-E10-*` (orchestrator log); your journal is the branch record

## Read this first — the experiment's real goal

E10 is the programme's **hold-default** experiment. Your job is to produce
the evidence for a hold/promote decision, not to build a feature that
deserves promotion. The deciding fact, measured by the orchestrator
pre-change: `Effect.fn __POS__` appears at **5 sites repo-wide** (3 in
tests) — E8's `[%eta.result]` already absorbed the boilerplate this sugar
was designed to eliminate. T4 says sugar follows demonstrated frequency.
The one-pager's gate: **hold by default even on success; promote only if
reviewers still ask for it after E7/E8; kill if generated-code error
locations rate ≤ 3 and cannot be improved.** A well-evidenced HOLD is a
success outcome for this experiment.

## Executor profile

ppxlib AST surgery with location discipline: an extension point
(`let%eta`) and a structure-item attribute (`[@@eta.trace]`) expanding to
`Effect.fn __POS__ __FUNCTION__ body`, with expansion snapshots,
error-location corpus, and an honest A/B review module. The difficulty is
ppxlib precision (ghost vs. preserved locations) and neutral presentation
of two spellings — not volume. Taste demand: moderate; the whole point is
judging whether the sugar *should* exist.

## Mission

Eta may be complicated inside; using Eta must feel beautiful — and sugar
that changes the shape of a *definition* is where sugar starts to read like
behaviour. Hold that bar.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file.
2. `lib/ppx/ppx_eta.ml` — the existing `expand_sync_like` path
   (`[%eta.sync]`, `[%eta.result]`) and the `eta_error` deriver; your
   expansion reuses `Effect.fn __POS__ __FUNCTION__` the same way.
3. `lib/eta/effect.mli` — the `fn` contract.
4. `test/ppx_expansion/` — the snapshot infrastructure from E7/E8.
5. `.scratch/research/dx/e8/report.md` — what leaf sugar already covers.

## The experiment (one-pager, from DX-PRD-0001 §E10)

`Effect.fn __POS__ __FUNCTION__` wrapping is mechanical but visually heavy
at the definition site. Proposal (experiment only):

```ocaml
let%eta f x = body    (* or *)    let f x = body [@@eta.trace]
(* both expand to *)
let f x = Effect.fn __POS__ __FUNCTION__ body
```

Wraps the body's result position (after all labeled/optional arguments);
`let rec` allowed (wrapper inside — recursive calls re-enter `fn`; define
and document the span semantics); expansion stays one line. `.mli`
signatures unchanged (wrapper is representation-level) — verify explicitly.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Your proof obligations: the expansion is exactly the one-liner above in all
shapes; error locations stay honest; the frequency question is answered by
data, not vibes.

Working artifacts in `.scratch/research/dx/e10/` **on this branch**
(commit them): `journal.md`, `report.md`, `redteam/`, `review/`.

## Protocol

1. **Seal your predictions** in `.scratch/research/dx/e10/journal.md`
   before any code change (`docs(dx-e10): seal predictions`): expected
   expansion shapes, expected error-location quality, your predicted review
   outcome (hold/promote/kill). Never edit afterward.
2. **Implement both spellings** (they share one expansion path — both are
   needed for the A/B; if promoted, only ONE lands, chosen by review).
3. **Mechanical evidence.**
   - Expansion snapshots in `test/ppx_expansion/`: plain function,
     labeled args, optional args, `let rec`, multi-arg currying. Each
     expansion must be the exact one-liner — code a reviewer would accept
     verbatim (T4).
   - **Error-location corpus**: deliberately mistyped bodies (wrong return
     type; non-effect body; type error deep inside the body). Snapshot the
     compiler output for the error board. If locations point into ghost
     code, try to fix the location placement; record what is and isn't
     improvable.
   - Verify `.mli` invariance: a module using the sugar compiles against
     the same `.mli` as its hand-written twin.
   - Gates:
     ```sh
     nix develop -c dune build @install
     nix develop -c dune runtest --force
     nix develop -c eta-oxcaml-test-shipped
     ```
     PPX is compile-time; no JS-track impact expected — flag if you find
     otherwise.
4. **Red-team pass** in `.scratch/research/dx/e10/redteam/`: (a) a
   non-effect body under the sugar — the error message quality *is* the
   finding; (b) a `let rec` helper — do the spans say what a reader would
   expect (per-call vs. once)? Record the actual span output via the
   in-memory tracer.
5. **Review packet** in `.scratch/research/dx/e10/review/`:
   - A real A/B: convert **at least one genuine repo site** (pick from the
     5 remaining `Effect.fn __POS__` sites) plus a small realistic module
     with 2–3 `fn`-wrapped definitions, each in three forms:
     `*-handwritten.ml`, `*-let.ml` (`let%eta`), `*-attr.ml`
     (`[@@eta.trace]`). 10–30 lines per file.
   - `MANIFEST.md`; `QUESTIONS.md` — must include: "what does the sugar
     expand to?" (guess-the-semantics), "does it change behaviour or only
     tracing?", and the hold-gate question, phrased neutrally: "The
     underlying pattern appears at 5 sites in this codebase. Would you
     reach for this sugar? Why?"
6. **Report** in `.scratch/research/dx/e10/report.md`: expansion corpus
   results, error-location corpus + your rating of it against the kill
   gate, frequency analysis, red-team outcome, predictions scored, and
   your own hold/promote/kill recommendation against the one-pager's
   gates.

## Done means

Your final message ends with exactly one of:

- `E10 READY FOR REVIEW`
- `E10 BLOCKED: <reason>`
- `E10 STOP: <§4.6 stop condition>`

The orchestrator verifies, runs the independent review cohort (≥3
comparable passes before gate evaluation), and decides. Remember: HOLD is
the default and a perfectly good outcome.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E10 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Stay in E10's surface: `lib/ppx/`, `test/ppx_*`, your research dir. Do
  NOT convert call sites beyond what the review packet needs — if
  promoted, conversion is a separate step. Adjacent footguns → journal
  follow-ups.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e10/` must be committed.
