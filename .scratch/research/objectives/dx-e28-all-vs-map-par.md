# Objective: DX-E28 — `all` vs `map_par` T1 audit

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e28`
- Branch: `research/dx-e28-all-vs-map-par` (already checked out here; do not create others)
- Phase: queued candidate (post-E30) · Effort S · Risk low · **audit experiment — the deliverable is a decision with evidence, not an API change**
- Evidence IDs: `V-DX-E28-*` (orchestrator log); your journal is the branch record

## Executor profile

Forensic API audit. Read-heavy, write-light: classify ~170 call sites,
read git history for design intent, compare two runtime engine paths, and
turn the result into a crisp contract. The difficulty is honest
classification (no flattening of inconvenient cases) and resisting the
urge to "fix" code — you decide, you document; code changes only within
the pre-registered outcomes below.

## Mission

T1: one obvious way per task. Today `Effect.all` and `Effect.map_par`
overlap (`all xs ≈ map_par Fun.id xs`) but differ in concurrency bound —
and nothing tells the user which to reach for. Either they are two ways
for one task (merge) or two tasks (differentiate with a crisp contract).

## Read first (in order)

1. `AGENTS.md` — rules.
2. `lib/eta/effect.mli` — `all`, `all_settled`, `map_par`, `par` docs.
3. `lib/eta/effect_concurrent.ml` — `all_eval`/`par_collect` (fork per
   effect, unbounded) vs. `map_par_workers` (worker pool, default 8).
4. `docs/api-dx.md` — current concurrency guidance.
5. `.scratch/research/dx/e24/report.md` — how `map_par` got its bound.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
This is a production decision between named candidates; build the
hypothesis ledger and let evidence close it. Artifacts in
`.scratch/research/dx/e28/` **on this branch** (commit them):
`journal.md`, `census.md`, `report.md`.

## The audit (pre-registered outcomes)

**Step 1 — Origin check.** `git log -S`/blame: was `all`'s unbounded
fork-per-effect a deliberate design act, or did it predate the
worker-pool optimization (cap 8) that `map_par` inherited? Cite commits.

**Step 2 — Engine census.** Classify every `Effect.all` and
`Effect.map_par` call site in `lib/ test/ examples/ bench/ http-testsuite/
drivers/` into: (a) small literal list (≤ 5), (b) collection mapping,
(c) large/dynamic list into `all`, (d) 2–3 literal into `map_par`.
Table with counts and the pathological cases quoted verbatim in
`census.md`.

**Step 3 — Decide** between:

- **C1 — Differentiate (keep both).** `all` = known handful of ready
  effects (unbounded by design, small n); `map_par` = mapping a
  collection (bounded, default 8). Deliverable: mli sentences stating the
  bound semantics of each + the "which one" rule, and a
  `docs/api-dx.md` concurrency table with exactly one recommended form
  per task shape (T1).
- **C2 — Merge.** `all` deleted, `map_par` absorbs (`max_concurrent:`
  length). Only if census shows the two tasks don't exist in practice.
- **C3 — Escalate.** Census finds `all` with large/dynamic lists in real
  (non-test) code — a live fork-bomb footgun. Stop, write the design
  options (bound `all` semantically / merge / accept), and report
  BLOCKED; that is a semantics decision the orchestrator takes.

Predicted winner is C1; that is a prediction, not permission — if the
census says otherwise, follow the census.

**Semantics & edges.** If C1: `all`'s mli must state the unbounded
fan-out honestly (one fiber per effect) and when that is fine (small,
known n) vs. dangerous (arbitrary n → `map_par`). No runtime behavior
changes in any C1 deliverable. jsoo: docs-only.

## Protocol

1. **Seal your predictions** in `journal.md` (census percentages, origin
   answer, decision, census/footgun deltas) — commit before any
   investigation (`docs(dx-e28): seal predictions`). Never edit afterward.
   (Dual-sealing: orchestrator's set is on master in the inherited file;
   do not read it — fence below.)
2. **Census first, decision second** — in that order, with the census
   committed (`census.md`) before the decision is written.
3. **Deliverable** per the chosen candidate (mli + api-dx edits if C1).
4. **Gates** (exact):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   ```
   Docs-only changes: state that and run them anyway. Fix-forward ≤ 3
   attempts per failure class, then BLOCKED.
5. **Mechanical extras:** the census table itself (primary artifact);
   census/footgun actuals vs. predictions; if mli law-bearing prose is
   added, registry rows per AGENTS.md's law policy (LAWS.md).
6. **Red-team pass:** write the wrong choice per your contract (e.g.,
   `all` over a 10k-dynamic list) and state whether the new docs sentence
   catches it at review time; if it doesn't, the contract isn't crisp
   enough — iterate.
7. **Report** in `report.md`: origin answer, census, decision with
   hypothesis-ledger statuses for C1/C2/C3, prediction scoring, red-team,
   and your promote/hold/kill recommendation.

## Done means

- `E28 READY FOR REVIEW`
- `E28 BLOCKED: <reason>` (C3 escalation is a BLOCKED signal with the
  design options written)
- `E28 STOP: <§4.6 stop condition>`

Orchestrator verifies (census audit on a sample, contract review), runs
the PR-style oracle review, and decides.

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md` (orchestrator's
  sealed predictions), `docs/research/`, `.scratch/research/dx-prd-0001.md`,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- No runtime code changes. mli/docs changes only, and only if C1 wins.
- `objective.md` stays uncommitted; everything under
  `.scratch/research/dx/e28/` must be committed.
