# Objective: DX-E23 — Error channel mirrors `Result`

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e23`
- Branch: `research/dx-e23-result-error-channel` (already checked out here; do not create others)
- Phase: A (idiom pass) · Effort M · Risk low
- Evidence IDs: `V-DX-E23-*` (orchestrator log); your journal is the branch record

## Executor profile

Large mechanical rename across an OCaml 5 codebase (~51 source files, ~220
call sites, plus docs), plus one small new combinator (`fold`), plus
discipline artifacts (predictions, census, red-team, review packet). The
difficulty is thoroughness and protocol compliance, not design: every
signature is dictated below. Do not invent, do not "improve" adjacent code,
do not widen scope.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. This
experiment's north star: *`Effect` is `Result` with concurrency and spans —
`map`/`map_error` on values, `bind`/`bind_error` on sequences, `fold` on both
channels.* Judge every naming decision by whether it moves toward that
sentence.

## Read first (in order)

1. `AGENTS.md` — its rules outrank everything except this file. Note
   especially: Nix-only gates, no shims/compat layers, delete old paths,
   break loudly, conventional commits.
2. `lib/eta/effect.mli` lines ~150–320 (the handle cluster) and the
   corresponding `effect.ml`.
3. `docs/api-dx.md` — the document this experiment partially obsoletes; you
   will rewrite its error-handling guidance.
4. The error-channel sections of `docs/zio-boundaries.md`.

## Method

This programme uses the evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
For this experiment the design is already decided (signatures below are the
contract), so skip hypothesis-space theatre. Your proof obligations are:
migration completeness (zero stale references), behavior parity (renames
change nothing), and honest `fold` semantics (it is the one new behavior).

Your working artifacts live in `.scratch/research/dx/e23/` **on this branch**
(commit them): `journal.md` (your decision log), `report.md` (final report),
`review/` (blind-review packet, see step 7). The orchestrator archives them;
master never sees them unless this branch merges.

## The experiment (one-pager, from DX-PRD-0001 §E23)

**Proposal.**

```ocaml
val bind_error : ('err1 -> ('a, 'err2) t) -> ('a, 'err1) t -> ('a, 'err2) t
  (* rename of catch; data-last, pipeline-friendly *)
val fold : ok:('a -> 'b) -> error:('err -> 'b) -> ('a, 'err) t -> ('b, 'outer) t
  (* pure both-channel fold, mirrors Result.fold; REPLACES recover *)
val to_result : ('a, 'err1) t -> (('a, 'err1) result, 'err2) t   (* was result *)
val to_option : ('a, 'err1) t -> ('a option, 'err2) t            (* was option *)
val to_exit   : ('a, 'err1) t -> (('a, 'err1) Exit.t, 'err2) t   (* was exit *)
```

Deletions (no shims, changelog is the migration guide): `catch`, `recover`,
`or_else_succeed`, and the bare nouns `result` / `option` / `exit`.
`catch_some` keeps its name (reads as a filter; no Stdlib analogue).
`or_else` stays (parser-culture name, thunk fallback).

**Semantics & edges.** None — renames plus one new composite (`fold` is
`map`∘recovery). Migration is compiler-guided: delete, build, fix.
`catch_some`'s doc cross-references move to `bind_error`.

**Verification target.** Full-repo migration incl. `lib/`, `test/`,
`examples/`, `bench/`, docs; census delta (handle cluster 10 concepts → 8);
footgun delta: the top trap ("`catch` catches exceptions") removed by
construction.

## Protocol (in order; each step committed separately)

1. **Seal your predictions.** Write `.scratch/research/dx/e23/journal.md`
   with a `Predictions (sealed)` section: your expected teach-back answers
   ("what does `bind_error` do to defects?"), expected census/footgun
   deltas, and the two likeliest reviewer misreadings. **Commit this before
   any code change** (`docs(dx-e23): seal predictions`). The branch history
   proves sealing; never edit predictions afterward — wrong predictions are
   data.
2. **Docs-first.** Rewrite the affected `.mli` doc comments for
   `bind_error` / `fold` / `to_result` / `to_option` / `to_exit` /
   `catch_some` before touching `effect.ml`. Each contract ≤ ~10 lines; if
   `fold` needs more, that is a design smell — note it in your journal.
3. **Implement the smallest change.** `fold` is the only new behavior
   (`map`∘recovery composition); everything else is delete-and-rename.
   Migrate every call site the gates build, including docs code blocks.
4. **Gates** (from the worktree, exact commands):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   ```
   JS-track gates are not required (orchestrator verified: zero call sites
   in `lib/js`, `lib/jsoo`, `lib/js_stream`, `lib/js_test`, `lib/http_js`).
   If you discover one anyway, stop and flag it in your journal and report.
   Fix-forward up to three attempts per failure class, then BLOCKED.
5. **Mechanical extras.**
   - `fold` unit tests: coherence with `map`/`bind_error` composition;
     defects and interruption pass through untouched.
   - Census table in your journal: before/after val counts per cluster
     (orchestrator's pre-counts: handle cluster 11 vals / 10 concepts →
     expect 10 vals / 8 concepts; verify independently).
   - Footgun delta: traps removed / added (expect −1/+0).
   - Update `docs/api-dx.md` error-handling guidance to the new spellings —
     this is the easiest step to forget; it is an explicit checklist item.
6. **Red-team pass.** Deliberately write the bug the *old* name invited:
   use `bind_error` intending to swallow an exception. Record what actually
   happens (defect surfaces via `Die`, span status, `Cause` rendering) and
   whether anything in the new shape still invites the mistake. Commit the
   probe under `.scratch/research/dx/e23/redteam/` with a one-paragraph
   verdict in your journal.
7. **Review packet** in `.scratch/research/dx/e23/review/`, labeled (the
   orchestrator blinds it):
   - `w1-old.ml` / `w1-new.ml`: the same W1 program (read user 42 via a
     `result`-returning `Db.find`; default on `` `Not_found ``; crash must
     surface as defect) written against the old names and the new names.
     10–30 lines each, self-contained, realistic.
   - Two more call-site pairs from your real migrated code (pick the
     prettiest and the ugliest), as `site2-old.ml`/`site2-new.ml`,
     `site3-old.ml`/`site3-new.ml`.
   - `MANIFEST.md`: one line per file — what it is, where it came from.
   - `QUESTIONS.md`: the teach-back prompts — "what does `bind_error` do to
     defects?", "what does `fold` do when the effect is interrupted?",
     "which combinator reifies defects into a value: `to_result` or
     `to_exit`?"
8. **Report.** Write `.scratch/research/dx/e23/report.md`: gates output
   summary, census/footgun actuals vs. your sealed predictions (score them
   explicitly), red-team outcome, deviations from this objective, and your
   own promote/hold/kill recommendation against the one-pager's gates.
   Commit everything.

## Done means

Your final message ends with exactly one of:

- `E23 READY FOR REVIEW`
- `E23 BLOCKED: <reason>`
- `E23 STOP: <§4.6 stop condition>`

The orchestrator verifies your work (diff, focused tests, evidence audit),
runs the blind review, and decides. Rework rounds happen via follow-up
messages through the intermediary.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md` (orchestrator's
  sealed predictions — reading them contaminates yours), `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E23 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (it is the contract; leave it uncommitted).
- Stay in E23's surface. Adjacent footguns you notice go into your journal
  as follow-up notes, not into this diff.
- `objective.md` at the repo root must stay uncommitted; everything under
  `.scratch/research/dx/e23/` must be committed.
