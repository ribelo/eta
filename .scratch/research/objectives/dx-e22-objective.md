# Objective: DX-E22 — Law-property test policy ("every law in an mli has a qcheck test")

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e22`
- Branch: `research/dx-e22-law-properties` (already checked out here; do not create others)
- Phase: E (research; flexible timing per plan) · Effort M · Risk low
- Evidence IDs: `V-DX-E22-*` (orchestrator log); your journal is the branch record
- Provenance: fused-effects' hedgehog law-testing culture

## Executor profile

Property-based test design over a monadic effect library. The difficulty
is not qcheck mechanics — it is stating the laws *honestly*: the
observation equivalence (what makes two effects "the same"), the
generator design (which blueprints are in the documented class), and the
cancellation/finalizer properties where careless statements are too
strong. No public API changes. One new test-only dependency (qcheck) to
wire into the test packages and the Nix flake. Careful, precise,
maintainer-grade taste for what a "law" is.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. The mli is
where users learn the model — and every sentence of that model should be
executable. Untested prose is where models drift.

## Read first (in order)

1. `AGENTS.md` — Nix-only gates, package boundary policy (qcheck is a
   TEST dependency; it must not touch the `eta` core package), commit
   conventions.
2. The E22 one-pager below — the contract.
3. `lib/eta/effect.mli` — the law-bearing prose you will make executable
   ("release runs on success, failure, defect, and cancellation"; "par
   is fail-fast"; …).
4. `lib/eta/schedule.mli`, `lib/eta/channel.mli`, `lib/eta/queue.mli`,
   `lib/eta/semaphore.mli` — the primitive law clusters.
5. `lib/test/eta_test.mli` (`Run`) — the golden-record engine for
   running generated blueprints deterministically.
6. `.scratch/research/dx/e12/journal.md` — E12's property-testing
   precedent (168 generated blueprints, poisoned-capability properties)
   and its honest-boundary style.

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`.
Working artifacts in `.scratch/research/dx/e22/` **on this branch**
(commit them): `journal.md`, `report.md`, `redteam/`, `review/`.

## The experiment (one-pager, from DX-PRD-0001 §E22)

**Problem.** Eta's mli files state contracts in prose ("release runs on
success, failure, defect, and cancellation"; "par is fail-fast").
fused-effects enforces a harder rule: every law stated in the
documentation has a generative test. The mli is where users learn the
model; untested prose is where models drift.

**Proposal.** Adopt the policy **"every law in an mli has a qcheck
test"**, bootstrapped with this initial law inventory:

- monad-ish: `map id`, `map f ∘ map g`, `bind` associativity,
  `pure`/`bind` left/right identity
- error channel: `bind_error` left-identity, `fold` coherence with
  `map`/`bind_error`
- concurrency: `par` result pair-order, fail-fast cancels sibling,
  `map_par` preserves input order under interleavings, `race` loser
  cancellation
- lifecycle: `finally` runs exactly once on each exit kind; scope LIFO;
  `with_resource` release on all exits
- primitives: `Channel` close fences, `Semaphore` cancellation safety,
  `Queue` close/error ordering
- schedules: monotone delays, `recurs n` step count
- E19/E20 (promoted): override restore on each exit kind, sibling
  isolation under `par`, intercept order (filter → attrs → transform →
  sink)

**Deliverables.** qcheck suite + a policy paragraph added to
`AGENTS.md` + a census of laws-per-mli as a tracked number.

**Gates.** Promote when the initial inventory is covered and the policy
paragraph lands. *Review:* maintainer-grade — does the law list read
like the model? Gaps found become footgun entries.

## Protocol (predictions commit FIRST and separately)

1. **Seal your predictions** in `.scratch/research/dx/e22/journal.md`:
   the observation equivalence you will use, the generator class, the
   laws you expect to need refinement (and why), census/footgun deltas.
   Commit before any code change (`docs(dx-e22): seal predictions`).
2. **The observation equivalence, stated first.** Before writing
   properties, write (in the journal and in the suite's header comment)
   the exact equivalence the laws are stated over — predicted:
   `Exit.t` + ordered observable events via `Eta_test.Run` under a
   seeded test runtime. If you choose differently, justify. This is the
   load-bearing definition; get it reviewed in your own journal before
   building on it.
3. **Dependency wiring.** qcheck into the test packages' dune deps and
   the Nix flake (check `nix develop -c ocamlfind list | grep -i qcheck`
   first; nixpkgs carries qcheck — if the flake needs an addition, make
   it minimally and note it in the report). qcheck must NOT appear in
   any installable package's depends.
4. **The suite.** One property per inventory law, generators for the
   documented blueprint class (E12's precedent: base leaves × recursive
   levels; arbitrary bind lambdas excluded and attacked adversarially
   instead). Deterministic seeds; failures print the counterexample.
   Where a law as stated in the mli prose turns out too strong, REFINE
   HONESTLY: record the original statement, the counterexample, and the
   corrected statement (mli fix included if the prose was wrong — prose
   bugs are bugs).
5. **Gates** (from the worktree):
   ```sh
   nix develop -c dune build @install
   nix develop -c dune runtest --force
   nix develop -c eta-oxcaml-test-shipped
   nix develop .#mainline -c dune build --build-dir=_build-mainline @install
   ```
   (jsoo: the suite is runtime-backed; if the properties are portable,
   run them under `test/js_jsoo` too — document the choice.)
   Fix-forward up to three attempts per failure class, then BLOCKED.
6. **Census + policy.** Laws-per-mli as a tracked number (a committed
   table or a generated count — pick a form that resists drift).
   Policy paragraph in `AGENTS.md`: "every law in an mli has a qcheck
   test" + how to add one (link to the suite).
7. **Red-team pass** (committed under `redteam/` with verdicts):
   (a) write a deliberately vacuous property (true regardless of
   implementation) — show how the suite/review catches that class
   (e.g. generation coverage checks, or the property is rejected in
   review); (b) try to find a REAL violation on master: pick the two
   laws you trust least, attack them with adversarial generators. A
   found violation is a named bug and a success, not a failure.
8. **Review packet** in `review/`: the law inventory as a readable
   document (`LAWS.md` — one line per law: name, statement, mli source)
   plus `QUESTIONS.md` for a maintainer-grade review ("does this list
   read like the model? what's missing? what's wrong?").
9. **Report** in `report.md`: gates summary, the observation equivalence,
   inventory coverage table (law → property → status), refinements with
   their counterexamples, census/footgun actuals vs. sealed predictions,
   red-team outcomes, promote/hold/kill recommendation.

## Done means

Your final message ends with exactly one of:

- `E22 READY FOR REVIEW`
- `E22 BLOCKED: <reason>`
- `E22 STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond §E22 quoted above,
  `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- No public API changes. mli prose fixes are allowed ONLY where a law
  proved the prose wrong (each with its counterexample in the journal).
- Stay in E22's surface. Adjacent discoveries → journal follow-ups.
- Everything under `.scratch/research/dx/e22/` must be committed;
  `objective.md` stays uncommitted.
