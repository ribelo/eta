# Objective: DX-E4 + DX-E5 — Cause rendering corpus · type-error translations

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e4e5`
- Branch: `research/dx-e4e5-cause-corpus-type-errors` (already checked out here; do not create others)
- Phase: B (hygiene, batch 2) · E4 effort M risk low · E5 effort S risk low
- Evidence IDs: `V-DX-E4-*`, `V-DX-E5-*` (orchestrator log); your journal is the branch record

This is a BATCHED assignment: two independent experiments, one worktree,
one branch. They share only the docs/tests weight class. Keep them cleanly
separated: per-experiment journal sections, predictions, evidence,
recommendations. Either can promote without the other.

## Executor profile

Two flavors of documentation-grade work. E4: design a one-line rendering
notation for composite causes and a snapshot corpus that makes rendering
quality reviewable — taste in compact notation, plus a JSON encoder in
`eta_otel`. E5: compile-error archaeology — construct minimal repros that
trigger rank-2 escape errors and PPX rejections, snapshot the exact
messages, then write a translation page whose prose a tired user reads at
2am. Difficulty: OCaml type-system fluency (you must *produce* skolem
escapes on purpose), notation taste, and honest prose. No runtime semantics
change anywhere.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. Error
messages and rendered causes are API (T7). The test of this batch: a user
who just hit the wall reads your output and knows what happened, where,
and what to do next — without reading the implementation.

## Read first (in order)

1. `AGENTS.md` — outranks everything except this file. Nix-only gates, no
   shims, delete old paths, break loudly, conventional commits.
2. `lib/eta/cause.mli` + `cause.ml` — the tree type, `pretty`, `Portable`,
   `to_portable`. (E4)
3. `test/core_common/cause_exit_common_suites.ml` — existing rendering
   test conventions. (E4)
4. `lib/eta/supervisor.mli` — the rank-2 surface (`'s` phantom, `child`,
   `Scope.t`, `body`). (E5)
5. `lib/ppx/ppx_eta.ml` — the rejection paths (`Location.raise_errorf`).
   (E5)
6. `.scratch/research/dx/e23/journal.md` — executor-record format to match
   or beat.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Proof obligations: E4 — the corpus is machine-checked (expect tests +
newline-free property) and board-rated; E5 — the snapshots are real
compiler output (not typed from memory) and drift-gated.

Working artifacts in `.scratch/research/dx/e4/` and
`.scratch/research/dx/e5/` **on this branch** (commit them): `journal.md`
(one file with two clearly separated experiment sections is fine),
`report.md` (two sections), `review/` packets per experiment.

---

# EXPERIMENT E4 — Cause rendering: `pp_compact`, structured encoding, snapshot corpus

## The experiment (one-pager, from DX-PRD-0001 §E4)

**Problem.** `Cause.pretty` renders a multi-line tree, but: (a) no one-line
form exists for span statuses and log fields; (b) no structured encoding, so
sinks re-implement walks; (c) the tree rendering has no snapshot corpus —
its quality is unreviewed for the ugly cases (`Suppressed` × `Concurrent` ×
`Finalizer`, anonymous interrupts).

**Proposal.**

- Core: `Cause.pp_compact` — single line, e.g.
  `fail(Not_found) + interrupt | suppressed: finalizer(die(Unix.EPIPE))`.
- Structured encoding lives where JSON already lives: an
  `Eta_otel.Cause_json`-style encoder over `Cause.Portable.t`. Core stays
  JSON-free.
- Snapshot corpus: `pretty` + `pp_compact` for `Concurrent [Fail;
  Interrupt]`, `Suppressed { primary = Fail; finalizer = Die }`, nested
  `Finalizer (Sequential …)`, anonymous vs. identified interrupts,
  multi-defect composites.

**Verification.** Mechanical: corpus as expect tests; `pp_compact` never
emits newlines (property). Review: error review board rates the corpus;
every composite must answer what/where/what-next without mli reading.

**Gates.** Pieces promote independently. KILL the one-liner if compactness
destroys the primary/finalizer distinction (board verdict) — two-line logs
are also a finding.

## Protocol

1. **Seal predictions** (journal, E4 section): your compact-notation
   sketch, expected board ratings per corpus case, whether the kill gate
   fires. Commit before code (`docs(dx-e4): seal predictions`).
2. **Docs-first:** write the `pp_compact` mli contract (≤ 10 lines — what
   the segments mean, totality, newline-freedom) before implementing.
3. **Implement** `pp_compact`, the expect-test corpus, and
   `Eta_otel.Cause_json` (check first whether `eta_otel` already has cause
   encoding to extend — do not duplicate). Corpus minimum: the five cases
   in the one-pager, rendered both ways (`pretty` + `pp_compact`).
4. **Gates** (exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build test/cache_jsoo test/js_jsoo
   ```
   (Core `cause.mli` changes compile in the jsoo track too.)
5. **Mechanical extras:** newline-freedom property (qcheck or exhaustive
   corpus assertion); census delta (observability +1, eta_otel +1 module);
   footgun delta (expect +0/−0).
6. **Red-team:** construct the ugliest cause you can (deeply nested
   suppressed × concurrent × finalizer chains, empty composites if
   representable) — does `pp_compact` stay one line and stay truthful, or
   does it lie by omission? Record in the journal.
7. **Review packet** `.scratch/research/dx/e4/review/`: the corpus renders
   (the 5+ cases, both forms) as text files + `QUESTIONS.md` (per case:
   what happened / which is the primary failure / what ran in a finalizer /
   what would you check next?) + `MANIFEST.md`. Label clearly; the
   orchestrator blinds.
8. **Report** (E4 section): gates, corpus inventory, census/footgun
   actuals vs sealed, red-team outcome, and a per-piece recommendation
   (`pp_compact` / corpus / encoder — they promote independently). If the
   board would kill `pp_compact`, say so yourself first.

---

# EXPERIMENT E5 — Negative compile tests and an "Eta type errors, translated" page

## The experiment (one-pager, from DX-PRD-0001 §E5)

**Problem.** Scoped-handle safety relies on rank-2 types; the price is paid
in skolem-escape and quantification errors that are correct and unreadable.
OCaml lacks GHC-style custom type errors, so Eta's levers are PPX-time
messages, cram snapshots, and a translation page (T7).

**Proposal.**

- Cram-style negative compile tests capturing current messages for:
  `Supervisor` child-handle escape; resource-handle escape (where
  applicable); same-domain primitives (`Queue`/`Channel`/`Pubsub`/`Pool`)
  misused across `eta_par` domains; PPX rejection paths (already raised via
  `Location.raise_errorf` — review and snapshot their texts too).
- `docs/type-errors.md`: the 5–8 most common messages, each quoted verbatim
  from the snapshot, translated into what-you-tried / why-Eta-forbids /
  the two canonical fixes.

**Verification.** Mechanical: snapshots fail CI on message drift. Review:
W5 rigged to trigger the escape; reviewer solves with and without the
page; pass bar: with the page, the reviewer explains the rank-2 rationale
in their own words.

**Gates.** Promote unconditionally once the corpus lands; the by-product
is the list of messages needing compiler-side work.

## Protocol

1. **Seal predictions** (journal, E5 section): which of the one-pager's
   four categories will produce compile-time vs. RUNTIME errors (predict
   before checking!), the 5–8 messages you expect in the corpus, expected
   review outcome. Commit before code (`docs(dx-e5): seal predictions`).
2. **Archaeology first.** For each category, construct the minimal repro
   and capture the ACTUAL compiler output. If a category turns out
   runtime-only, record that as a finding — the page must say "this one
   fails at runtime, here is what it looks like" rather than forcing a
   compile error that doesn't exist.
3. **Snapshot harness.** The repo has no cram convention — introduce the
   lightest thing that works (dune cram stanzas or a small script +
   committed expected outputs). Requirement: `dune runtest` FAILS when a
   captured message drifts. Place under `test/type_errors/` or similar.
4. **Write `docs/type-errors.md`:** 5–8 entries, verbatim quoted message
   (matching the snapshot exactly — quote, don't paraphrase),
   what-you-tried, why-Eta-forbids, two canonical fixes. Budget: each
   entry ≤ ~15 lines.
5. **Gates:** native trio as above (jsoo compile check not needed unless
   you touched lib code — you should not need to).
6. **Red-team:** try to trigger the Supervisor escape in the way a real
   user would (return a child from `Supervisor.scoped`, leak it via a
   ref, etc.) — capture whatever error actually appears, even if it's not
   the one you expected. Surprises are corpus material.
7. **Review packet** `.scratch/research/dx/e5/review/`: a rigged W5 task
   (code that triggers the escape) as `w5-rigged.ml`, the relevant page
   excerpt as `page-excerpt.md`, the raw error text as `error.txt`,
   `QUESTIONS.md` (solve-without-page vs. solve-with-page protocol for the
   reviewer, ending with "explain the rank-2 rationale in your own words"),
   `MANIFEST.md`.
8. **Report** (E5 section): corpus inventory with per-item
   compile-vs-runtime verdict, page entry list, the compiler-side-work
   by-product list, census/footgun vs sealed, review outcome,
   recommendation.

---

## Shared rules

- **Gates run once per experiment completion AND once at the end** with
  both landed.
- **Done means** your final message ends with exactly one of:
  `E4+E5 READY FOR REVIEW` / `BLOCKED: <reason>` / `STOP: <§4.6 condition>`
  (if one experiment blocks and the other is done, say so explicitly —
  they decide independently).
- **Scope fence:** never read `.scratch/research/dx-journal.md`,
  `docs/research/`, `.scratch/research/dx-prd-0001.md` beyond the sections
  quoted here, `.scratch/research/orchestrator-state.md`. Never push,
  never commit to master, never create branches. `objective.md` stays
  uncommitted; everything under `.scratch/research/dx/e4/` and `e5/` is
  committed.
- Stay in scope. Adjacent footguns → journal follow-ups. Surprises
  (runtime-vs-compile, unexpected messages) are findings, not failures —
  record them raw.
