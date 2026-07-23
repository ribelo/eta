# DX-PRD 0001: Eta DX Experiment Plan & Autonomous Research Playbook

## Amendment 1 — Orchestration topology (2026-07-18; supersedes §0.2, §4.1–4.2, §4.5.2, Appendix E where noted)

The programme runs as a human-relayed multi-agent topology:

- **Orchestrator** (persistent pi session): seals predictions in
  `.scratch/research/dx-journal.md` on master *before* each branch is cut;
  creates worktrees (`Eta-dx-e<NN>` sibling dirs; branches
  `research/dx-e<NN>-<slug>`, pushed); writes each worktree's `objective.md`;
  verifies executor output (diff vs. scope, focused tests, evidence↔conclusion
  audit); assembles and blinds review packets and runs blind reviews in
  fresh-context oracle sessions; decides promote/hold/kill; merges, pushes,
  cleans up; curates durable conclusions into `docs/research/dx.md`.
- **Intermediary** (the human): relays start messages and completion signals
  between orchestrator and executor sessions. Holds veto authority over
  everything; their instructions outrank this document.
- **Executor** (fresh pi session per experiment): reads `objective.md`, seals
  its own predictions in its branch journal *before its first code commit*,
  implements docs-first, gates, red-teams, assembles labeled review material,
  and reports.

Journal architecture (supersedes §4.1/Appendix E): three tiers —
1. Executor journal `.scratch/research/dx/e<NN>/journal.md`, committed on the
   experiment branch (evidence-based-coding discipline: verdicts tied to
   runnable artifacts).
2. Orchestrator programme log `.scratch/research/dx-journal.md` (`V-DX-*`,
   append-only). The legacy `.scratch/research/journal.md` is frozen history.
3. Durable curated conclusions `docs/research/dx.md`.

Predictions are dual-sealed (orchestrator on master pre-branch; executor on
branch pre-code) and scored against each other at results time. Blind review
runs on a fresh oracle session with a fixed persona per programme; snippets
are 10–30 lines, caller-visible context only, no rationale, blinded and
randomized by the orchestrator (executor material stays labeled). Execution
is sequential; batching several experiments into one worktree is the
orchestrator's call (supersedes §0.2's one-experiment-one-worktree rule when
exercised). Stop conditions §4.6 and the taste constitution §2 are unchanged.

Status: execution-ready · v2 · 2026-07-18
Executor: an autonomous coding agent ("pi") running unsupervised
against private clones/worktrees of `ribelo/eta`.
Scope: `lib/eta` core (`Effect`, `Syntax`, `Cause`, `Exit`), `ppx_eta`,
`eta_test`, concurrency model, docs, plus API-renaming ("idiom pass") and
findings imported from `fused-effects` / `polysemy`.

Non-goals: ZIO/Effect-TS API parity, `Layer` / `Tag` / `Context` / `provide`,
STM, a service locator of any kind, a type-level effect stack, and any change
to the project axiom *applications own state; Eta owns effect description and
interpretation*.

---

## 0. How to use this document (read first, executing agent)

You are the executing agent. This document is the single source of truth for
the research programme. It is written so you can run end-to-end without human
intervention. Your invariants:

1. **Read `AGENTS.md` of the repo before touching code.** Its rules
   (Nix-only gates, delete-old-paths, break loudly, commit conventions) outrank
   this document wherever they conflict, except that this document owns the
   research protocol (journal, predictions, reviews, gates).
2. **One experiment = one git worktree = one branch.** Never mix two
   experiments in one worktree or one branch.
3. **The journal is append-only** (`.scratch/research/journal.md` in the main
   checkout). You never edit or delete existing entries; corrections are new
   entries that reference the old ones.
4. **Predictions are sealed before implementation.** You write expected
   outcomes into the journal *before* writing code. This is the spine of the
   whole programme; skipping it turns research into decoration.
5. **Statuses live in §6.** After every experiment you update the dashboard
   row and the journal. After every phase you write a phase synthesis.
6. **Kill is a first-class outcome.** An experiment killed with recorded
   evidence is a success. Pre-registered kill criteria are sacred: when they
   fire, you kill, record, and move on.
7. **Stop conditions (§4.6) are the only things that halt you.** Taste
   questions, renames, and breaking changes are yours to decide within an
   experiment's one-pager. The library is private and unfrozen; breakage is
   expected and batching is planned.

## 1. Why this document exists

Eta's API is well-designed. Its remaining DX problem is not missing features —
it is the number of near-identical concepts a user must choose between
correctly, plus a naming layer inherited from ZIO that fights OCaml's existing
mental models:

- construct: `pure` / `sync` / `from_result` / `from_option` / `flatten_result`
- handle: `catch` / `catch_some` / `recover` / `or_else` / `or_else_succeed` /
  `result` / `option` / `exit` / `ignore` / `ignore_errors`
- iterate: `for_each_par` / `for_each_par_bounded` / `retry` / `retry_or_else`
- lifecycle: `finally` / `on_exit` / `on_error` / `on_interrupt` /
  `with_resource` / `with_resource_exit` / `acquire_release` / `scoped`

Three symptoms confirm the load: (1) `docs/api-dx.md` must exist to steer
users away from less-preferred forms; (2) the recommended leaf pattern is two
combinators deep (`sync f |> flatten_result`); (3) the default telemetry for
typed failures is the literal string `"<typed failure>"`.

**North star.** The API should be teachable in one sentence: *"`Effect` is
`Result` with concurrency and spans — `map`/`map_error` on values, `bind`/
`bind_error` on sequences, `fold` on both channels."* Every rename in this
programme is judged by whether it moves Eta toward that sentence.

**Imported findings.** A scan of `fused-effects` and `polysemy` (Haskell
algebraic-effect systems) produced four adoptable ideas (scoped capability
override, log/metric interception, `Fresh`, law-property testing culture), two
pedagogy upgrades (algebra/carrier ↔ blueprint/runtime framing; library-owned
error-message UX), and a list of confirmed non-imports (type-level stacks,
tactics, `Labelled`/`Tagged`, `NonDet`/`Cut`, `Final`, zero-cost claims). These
enter the catalog as DX-E19…E22 and DX-E26; the rationale sections cite the
source libraries.

The programme has 26 experiments in five phases. Each is cheap to run, has a
pre-registered kill criterion, and is verified twice: mechanically, and by the
structured review protocol of §3, executed autonomously per §4.

## 2. Taste constitution

Every experiment is judged against these principles. Each has a check, so
"good taste" is operational. They extend the engineering rules in `AGENTS.md`
(no shims, break loudly, delete old paths, churn is not an argument).

**T1 — One obvious way per task.** For any walkthrough task (§3.4), the docs
name exactly one preferred primitive; alternatives are marked lower-level.
*Check:* pick a task, find the docs' answer. Two "recommended" answers = fail.

**T2 — The wrong thing looks wrong, and ideally does not compile.**
*Check:* the red-team pass (§3.3) states the invited bug in one sentence; if
that bug is invisible in a PR diff, the shape fails.

**T3 — Names carry the failure channel.** From the call site alone, a reader
can tell whether a combinator touches typed failures, defects, interruption,
or finalizers.
*Check:* channel-blind reading — reviewer sees only the call site and names
the channels affected.

**T4 — Boilerplate is a symptom; sugar only for unambiguous boundaries.**
*Check:* every PPX expansion is code a reviewer would accept verbatim in a PR.

**T5 — The blueprint is a value: inspectable, printable, auditable.**
`Effect.t` is reified (`collect_names` proves it). Static claims in docs are
machine-checkable, not asserted in prose.
*Check:* every "never sleeps / always releases / cannot escape" claim is
backed by introspection or a test.

**T6 — Observability defaults must mean something.** A span status of
`"<typed failure>"` is a DX bug.
*Check:* span statuses in `examples/` render domain-meaningful strings for
100% of declared error types.

**T7 — Error messages are API.** Compiler errors, runtime defects, and `Cause`
rendering share the review bar of function signatures.
*Check:* the error rubric (Appendix A.2): what happened / where / what next.

**T8 — Docs-first, with a budget.** The mli contract is written before the
implementation; > ~10 lines to state it means the combinator is suspect.
*Check:* doc budget overruns trigger redesign, not more prose.

**T9 — No ambient magic.** Configuration travels as values or explicit runtime
capabilities. PPX never infers services and introduces no names absent from
the use site.
*Check:* read the expansion; every identifier traces to the use site or to
`__POS__` / `__FUNCTION__`.

**T10 — Portability fence.** Every new core primitive names its semantics on
at least two substrates (native Eio and js_of_ocaml).
*Check:* the experiment's one-pager contains a jsoo paragraph before work
starts (ADR 0001 is the model).

**T11 — Mirror Stdlib/ecosystem mental models where they exist.** When OCaml
already owns a mental model (`Result.map`/`map_error`, `bind`/`bind_error`,
`List.map ~f`, `Option.to_result`, `Fun.protect`, `Eio.Switch.run`, `Logs`),
Eta uses the same shape and the same name. Novel names only for concepts OCaml
does not already have.
*Check:* for every renamed or new combinator, name the Stdlib/ecosystem
analogue it mirrors — or state explicitly that none exists.

## 3. Verification methodology

### 3.1 Mechanical verification

Baseline gates, run in the experiment's worktree for every experiment:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
# when touching JS-track code:
nix develop .#mainline -c dune runtest test/http_js --force   # and relevant JS targets
```

Per-experiment additions:

- **Expect/snapshot tests** for all rendered output: `Cause.pretty`,
  `Effect.describe`, PPX expansions (printed AST), span statuses.
- **Negative compile tests** (cram-style `ocamlc` error snapshots) for every
  type-level guarantee and every PPX rejection path.
- **Property tests** (qcheck) where semantics allow: finalizer ordering,
  mask-stack laws, audit-flag vs. behaviour consistency, promise
  single-resolution, channel/semaphore fences.
- **API census.** A script or manual table counts public values per concept
  cluster (construct / handle / iterate / lifecycle / concurrency / background
  / observability / logging / metrics / syntax operators / PPX forms) before
  and after the experiment. A change that grows a cluster needs explicit
  justification; merges and renames that shrink clusters are preferred.
- **Footgun budget.** The footgun list in `README.md` / `docs/api-dx.md` is
  the tracked trap inventory. Each experiment logs its delta: traps removed,
  traps added. Direction of travel: down.

### 3.2 Human-substitute verification (autonomous edition)

The reference version of this programme used live humans. The executing agent
runs unattended, so every subjective protocol is replaced by a structured
agent protocol with two defences against self-dealing: **sealed predictions**
and **fresh-context blind review**. Agent-run protocols are weaker than real
users; §4.5 marks the evidence accordingly, and wave syntheses flag the
experiments whose promote decision most needs a human spot-check later.

**Personas.** Three personas are role-played *from documentation only* — the
reviewer session must not read the implementation while persona-working:

- **P-OCaml**: experienced OCaml developer, never used an effect system.
  Will misread `ignore`, `catch`, `result`; trusts Stdlib naming.
- **P-ZIO**: ZIO / Effect-TS refugee. Expects `catchAllCause`, `FiberRef`,
  `Layer`; will misjudge their absence.
- **P-Maint**: library author. Used for semantics-heavy experiments where the
  user writes interpreters, not applications.

**Sealed predictions.** Before implementation, the experimenter writes into
the journal: the expected path per walkthrough task, the two most likely
mistakes per persona, and the predicted review ratings. Sealed = committed in
the journal entry before the first code commit on the branch.

**Fresh-context blind review.** For shape changes and A/B comparisons, a
**separate reviewer session** (new conversation / subagent with no shared
context) receives before/after or option-A/option-B snippets in randomized
order, without labels, without the experiment's goal. The reviewer rates each
snippet on the anchored scale and answers guess-the-semantics questions
*before* seeing any rating rubric result. If the runtime cannot spawn a
separate session, the experimenter writes the snippets to files and performs
the review after a context reset; the method used is recorded in the journal.
Self-review of one's own diff in the same context does not count.

**Anchored Warm Vibe Scale.** Artifacts are rated 1–5. Anchors for an API
call site:

- **5** — approve in a PR without comment; semantics obvious from names;
  nothing invites a mistake.
- **4** — clear after zero or one doc lookup; nothing actively misleading.
- **3** — understandable after a doc check, or one name pulls the wrong way.
- **2** — meaning recoverable only from the implementation, or initially
  guessed wrong.
- **1** — would write the bug this API invites.

Rubrics for error messages and doc pages: Appendix A. Default pass bar:
median ≥ 4 with no rating ≤ 2, unless an experiment states otherwise.

**Error review board.** The reviewer session rates compiler/runtime messages
on the three rubric questions (what / where / what next) plus: "would P-OCaml
confuse typed failure with defect here?" Sub-bar messages get rewritten or get
a translation-page entry (DX-E5).

**Red-team pass.** The experimenter deliberately writes the bug the API
invites (swallowed error, leaked handle, lost cancellation, mis-classified
defect), in the worktree, and records the attempt. If the bug compiles cleanly
and is invisible in a diff, T2 fails.

**Teach-back from docs.** The reviewer session reads only the docs for 20
minutes (simulated: docs files only, no source), then explains from memory:
`bind_error` vs `fold` vs `to_result` vs `ignore_errors` (post-idiom-pass);
`with_resource` vs `acquire_release` + `with_scope`; `and*` vs `Effect.par`.
Each wrong answer is a naming/docs failure attributed to the responsible
experiment.

**Screenshot test.** Paste the call site or test into a PR-sized block and
judge it cold: operators on the hottest line, nesting depth, distinct concepts
visible, plus the 1–5 rating. Code that works but looks noisy loses — noise is
where bugs hide.

### 3.3 Decision gates and evidence

Every experiment ends in exactly one state:

- **promote** — merged to `master` behind the normal gates;
- **hold** — branch kept, worktree removed, missing evidence stated;
- **kill** — abandoned; branch kept for provenance, reason recorded.

Every outcome gets an evidence ID in `.scratch/research/journal.md`
(`V-DX-E1-001`, `V-DX-E1-002`, …), matching the repo's `V-*` convention, so
later design discussions cite evidence instead of re-arguing taste.

### 3.4 Walkthrough task set

Six fixed tasks. The same set is used for baseline (pre-change) and treatment
(post-change) passes, executed per §3.2.

- **W1 — Fallible leaf.** Read a user by id from a synchronous DB call that
  returns `result`; failures typed, exceptions defects.
- **W2 — Cleanup.** Guarantee a metric flush after an effect, on success,
  typed failure, and cancellation.
- **W3 — Concurrency.** Fetch a user and their permissions concurrently;
  collect both; state the sibling's fate on failure.
- **W4 — Timeout.** Bound an effect to 50 ms with a domain-specific timeout
  error (not raw `` `Timeout ``).
- **W5 — Supervision.** Start two children, let one fail, observe without
  failing the parent, await the other.
- **W6 — Testing.** Prove a retry policy slept exactly 10, 20, 40 ms, the
  finalizer ran, and no fiber is pending — without wall-clock sleeps.

## 4. Autonomous execution playbook

### 4.1 Setup and conventions

```sh
git clone git@github.com:ribelo/eta.git eta && cd eta   # main checkout ("main")
mkdir -p ../eta-wt                                       # worktree pool
```

- Journal: `.scratch/research/journal.md` **in the main checkout** (tracked,
  per AGENTS.md's research discipline). Append-only. If absent, create with a
  header entry `V-DX-000` describing this programme.
- Status dashboard: §6 of this document. The agent keeps a copy in the journal
  header and updates both.
- Branch naming: `dx/e<NN>-<slug>` (e.g. `dx/e23-result-error-channel`).
- Worktree naming: `../eta-wt/e<NN>`.
- Commits: conventional, imperative, scoped (per AGENTS.md), e.g.
  `feat: rename catch to bind_error across core and packages`.
- One experiment in flight per worktree; core-rename experiments (Phase A) run
  strictly sequentially; see §4.8.

### 4.2 The per-experiment loop

For the next experiment in the execution order (§7), in its one-pager order:

1. **Re-read the one-pager.** If the experiment's entry gate is not met
   (e.g. E17 needs E12 evidence), skip to the next and note the skip.
2. **Journal entry `V-DX-E<NN>-001` — sealed predictions** (§3.2): expected
   walkthrough paths, two likeliest mistakes per persona, predicted ratings,
   predicted census/footgun deltas. Commit to `master` before any branch.
3. **Worktree:**
   ```sh
   git worktree add ../eta-wt/e<NN> -b dx/e<NN>-<slug> master
   cd ../eta-wt/e<NN>
   ```
4. **Docs-first (T8).** Write/rewrite the `.mli` docs and the docs-page
   section for the change before implementing. If the contract exceeds the
   doc budget, stop and redesign on paper (journal note), then proceed.
5. **Implement** the smallest change satisfying the one-pager.
6. **Gates** (§3.1). Fix-forward up to three attempts per failure class; then
   see stop conditions.
7. **Mechanical extras** per one-pager: expect tests, negative compile tests,
   properties, census, footgun delta.
8. **Red-team pass** (§3.2). Record the attempt and outcome.
9. **Fresh-context blind review** (§3.2) where the one-pager requires it.
10. **Journal entry `V-DX-E<NN>-002` — results**: gates output summary,
    review ratings, teach-back accuracy, census/footgun deltas vs. sealed
    predictions (score predictions explicitly).
11. **Decision** per the one-pager's gates: promote / hold / kill, with a
    one-paragraph rationale. On promote: merge to `master`
    (`git merge --no-ff dx/e<NN>-<slug>`) and re-run the full gates on
    `master`. On hold/kill: keep the branch.
12. **Cleanup and bookkeeping:** `git worktree remove ../eta-wt/e<NN>`
    (branch stays), update §6 dashboard and the journal's dashboard copy,
    write follow-ups.

### 4.3 Journal entry template

```markdown
## V-DX-E<NN>-<seq> — YYYY-MM-DD — dx/e<NN>-<slug> — phase: <predict|results|decision>
Predictions (sealed) / Results / Decision: …
Gates: build @install [pass|fail] · runtest [pass|fail] · shipped [pass|fail]
Review: blind ratings […] median x · teach-back n/m · red-team: <outcome>
Census: <cluster> a→b · Footguns: −x/+y (<which>)
Decision: promote|hold|kill — <rationale>
Follow-ups: …
```

Phase synthesis (after each phase in §7): what the evidence says, which
predictions were wrong and why, plan adjustments, status table, and the
explicit list of promote decisions that most need a later human spot-check.

### 4.4 Evidence rules

- Entries are append-only; corrections reference the corrected entry.
- Every claim in a synthesis cites at least one `V-DX-*` entry.
- Numbers beat adjectives: census deltas, teach-back scores, ratings medians.

### 4.5 Anti-self-dealing rules

1. Predictions sealed before implementation — no exceptions.
2. Blind review only in a fresh context; self-review of one's own diff does
   not count as review.
3. Kill outcomes are expected. The programme pre-registers plausible kills
   (E10, E14 hold, E16 expected-kill, E17, E21). If a phase ends with zero
   kills, the phase synthesis must argue why the process is not rubber-
   stamping — explicitly, with evidence.
4. Agent-run persona evidence is labelled `[agent-sim]` in the journal; any
   promote decision resting *solely* on `[agent-sim]` evidence is flagged
   `spot-check` in the dashboard for later human review.
5. The experimenter never edits sealed predictions, even when wrong. Wrong
   predictions are the most valuable data in the programme.

### 4.6 Stop conditions (halt and wait for the human)

Stop the whole programme (write a journal entry `V-DX-STOP`) only when:

- the gates on `master` are red after a merge and three fix attempts fail —
  leave the worktree in place and report;
- an experiment demonstrably requires public API changes beyond its one-pager
  (write the discovered options to the journal, mark the experiment `hold`,
  continue with the next one — this pauses, not stops);
- a change would touch security/protocol-sensitive code (`eta_http*`, TLS,
  `eta_redacted` semantics) — mark `hold`, continue;
- a merge conflict with previously promoted experiments cannot be resolved
  without semantic judgement — mark `hold`, continue;
- credentials, network services, or external systems would be required.

Everything else — taste, renames, breakage, kill decisions — is yours.

### 4.7 Merge and cleanup policy

- Promote ⇒ merge `--no-ff` to `master`, re-run full gates on `master`, then
  `git worktree remove`. Branch stays pushed/local as provenance.
- Hold/kill ⇒ remove worktree, keep branch, journal explains.
- After each phase: phase synthesis entry + dashboard refresh + `master` gates
  green before the next phase starts.

### 4.8 Parallelism and conflicts

Phase A (idiom pass, E23→E24→E25) is strictly sequential: each renames core
surface and the next must rebase on the promoted previous. Phase B–D
experiments may be prepared in parallel worktrees but merge sequentially in
execution order. PPX experiments (E7, E8, E10) touch the same file
(`lib/ppx/ppx_eta.ml`) — never concurrent. When a rebase produces conflicts
in renamed identifiers, resolve mechanically (the rename map of Phase A is
the authority); semantic conflicts trigger §4.6.

## 5. Experiment catalog

Format per experiment: problem, proposal, semantics and edges, taste check,
verification (mechanical + review), gates, alternatives. Effort: S (< 1 day),
M (days), L (week+). Risk: model/semantics risk, not implementation size.
Phases and execution order are defined in §7; statuses in §6.

### Phase A — Idiom pass: batched breaking renames toward OCaml mental models

The library is private and unfrozen; this is the cheapest moment in its life
to fix inherited ZIO naming. Phase A is one changelog entry ("idiom pass")
produced by three sequential experiments. Guiding principle: T11 — the error
API should mirror `Stdlib.Result`, iteration should mirror `List`, and every
combinator should be teachable as "`Result` with concurrency and spans".

---

#### DX-E23 — Error channel mirrors `Result`: `bind_error`, `fold`, `to_*`

Phase A · Effort M · Risk low (mechanical rename; semantics unchanged)

**Problem.** `catch` is the worst name in the surface: it reads as
`try/catch`, invites the exact misconception the docs spend a section
refuting (it does not catch defects), and has no Stdlib analogue. OCaml
already owns the right mental model: `Result` has `map`/`map_error` and
`bind`/`bind_error`. Mirroring it makes the whole error channel teachable in
one sentence (§1 north star). Meanwhile `result` / `option` / `exit` are bare
nouns that read as constructors, and `recover` / `or_else_succeed` duplicate
what a labelled `fold` says better.

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

Deletions (per AGENTS.md — no shims, changelog is the migration guide):
`catch`, `recover`, `or_else_succeed`, and the bare nouns `result`/`option`/
`exit`. `catch_some` keeps its name (it reads as a filter; no Stdlib analogue
exists). `or_else` stays (parser-culture name, thunk fallback).

**Semantics & edges.** None — renames plus one new composite (`fold` is
`map`∘recovery). Migration is compiler-guided: delete, build, fix.
`catch_some`'s doc cross-references move to `bind_error`.

**Taste check.** T11 (mirrors `Result`), T3 (`bind_error` says the channel;
nobody expects it to catch exceptions, exactly as `Result.bind_error` would
not), T1 (handle cluster: 11 concepts → 8).

**Verification.** *Mechanical:* full-repo migration incl. `lib/`, `test/`,
`examples/`, `bench/`, docs; census delta (handle 11 → 8); footgun delta: the
top trap ("`catch` catches exceptions") is removed by construction. *Review:*
fresh-context teach-back from docs only — "what does `bind_error` do to
defects?" Pass bar: correct answer without doc lookup; blind A/B of the W1
snippet old vs. new naming, median ≥ 4. Sealed prediction required: expected
teach-back 3/3.

**Gates.** *Promote* if migration completes and teach-back confirms. *Hold*
individual renames only if the reviewer session shows a comprehension drop
for a specific name (record evidence; the rest still promote). This
experiment supersedes the earlier "error namespace" idea (`Effect.Error.*`):
mirroring `Result` beats inventing a namespace.

**Alternatives.** `Effect.Error.catch` namespace (rejected: new vocabulary
instead of an existing mental model). Keep `catch` + docs exhortation
(rejected: the status quo that produced the footgun section).

---

#### DX-E24 — Iteration mirrors `List`: `map_par`, one `retry`, slimmer `Schedule.t`

Phase A · Effort M · Risk low–med (Schedule.t type change ripples)

**Problem.** `for_each_par` violates OCaml naming intuition: `for_each` means
unit-returning iteration (`List.iter`), yet it collects results — it is a
`map`. `for_each_par_bounded` is a second function where OCaml would use an
optional argument. `retry` vs. `retry_or_else` is the same duplication, and
`Schedule.t`'s third type parameter exists only to thread effectful taps
through the schedule type — complexity that labelled observer arguments
eliminate.

**Proposal.**

```ocaml
val map_par :
  'a list -> f:('a -> ('b, 'err) t) -> ?max_concurrent:int -> ('b list, 'err) t
  (* absorbs for_each_par and for_each_par_bounded; Invalid_argument if
     max_concurrent <= 0 *)

val retry :
  ('a, 'err) t ->
  schedule:('err, 'out) Schedule.t ->
  while_:('err -> bool) ->
  ?on_retry:('err -> 'out option -> (unit, 'err) t) ->
  ?or_else:('err -> 'out option -> ('a, 'err) t) ->
  ('a, 'err) t
  (* absorbs retry_or_else; or_else receives None when the predicate rejects
     the first failure before any schedule step — current semantics preserved *)

val repeat :
  ('a, 'err) t -> schedule:('a, 'out) Schedule.t ->
  ?on_repeat:('a -> 'out option -> (unit, 'err) t) -> ('out, 'err) t
```

`Schedule.t` drops its third parameter (the effectful-tap channel) and
becomes `('in, 'out) Schedule.t`; taps leave the schedule type and become
observer arguments at the call sites. Deletions: `for_each_par`,
`for_each_par_bounded`, `retry_or_else`, the old `retry`/`repeat` shapes.

**Semantics & edges.** Fail-fast, input-order results, cancellation: all
unchanged. The `~f` label follows `List.map ~f` (T11). Observer failures
follow the current tap-failure rules (they fail normally through the typed
channel); the mli states it. Callers of schedule taps migrate to observers —
mechanical, compiler-guided.

**Taste check.** T11 (`List.map ~f`, optional args), T1 (iterate cluster:
5 concepts → 2), T8 (`Schedule.t` docs lose their hardest paragraph).

**Verification.** *Mechanical:* parity tests old vs. new shapes (result
order, fail-fast, bound enforcement, `or_else` receiving `None`/`Some`);
Schedule tap→observer migration tests; census (iterate 5 → 2; `Schedule.t`
params 3 → 2). *Review:* blind A/B of a bounded-parallel fetch and a
retry-with-fallback snippet; guess-the-semantics on `?max_concurrent` and
`~while_`; median ≥ 4.

**Gates.** *Promote* on parity green + review pass. *Hold* the `Schedule.t`
slimming specifically if the tap migration exposes uses that observers cannot
express (record; the renames still promote).

**Alternatives.** Keep both bounded/unbounded functions (rejected: optional
args are the OCaml shape). `iter_par` for unit work — add only if real usage
appears; not speculative.

---

#### DX-E25 — Family consistency: `with_scope`, `named ?kind`, `now_ms`, `error_pp`

Phase A · Effort S–M · Risk low

**Problem.** Four small inconsistencies, each cheap to fix now and annoying
forever: (a) `scoped` is the only non-`with_*` name in the lifecycle family;
(b) `named` and `named_kind` are two functions where one optional argument
suffices; (c) `now` returns a raw `int` of milliseconds with no unit in the
name; (d) `with_error_renderer` demands `('err -> string)`, forcing
`Format.asprintf "%a" pp_err` in every module — while OCaml's ecosystem
(`[@@deriving show]`, Format culture) already produces `pp` functions, and
the planned renderer deriver (DX-E7) should plug straight into them.

**Proposal.**

```ocaml
val with_scope : ('a, 'err) t -> ('a, 'err) t        (* was scoped *)
val named :
  ?kind:Capabilities.span_kind -> ?error_pp:(Format.formatter -> 'err -> unit) ->
  string -> ('a, 'err) t -> ('a, 'err) t             (* absorbs named_kind *)
val now_ms : (int, 'err) t                           (* was now *)
val with_error_pp :
  (Format.formatter -> 'err -> unit) -> ('a, 'err) t -> ('a, 'err) t
  (* was with_error_renderer; renders internally, once per failure *)
```

Deletions: `scoped`, `named_kind`, `now`, `with_error_renderer`, and
`?error_renderer` everywhere (`fn`, `named`). The `"<typed failure>"` default
is unchanged; only the injection shape changes.

**Semantics & edges.** None. `error_pp` output is rendered at most once per
span status/exception event; the pp must be total — a raising pp becomes a
defect via the ordinary capture path (document).

**Taste check.** T1/T11 (one name per verb family; Format culture), T6
(prepares the socket DX-E7's deriver plugs into: `[@@deriving show]`-style
`pp_err` drops straight in).

**Verification.** *Mechanical:* migration; census (observability cluster
−1); a golden span-status test rendering via `error_pp`. *Review:* small
blind A/B on the four call sites; teach-back: "which combinator opens a
resource scope?" answered instantly.

**Gates.** *Promote* wholesale unless a specific rename measurably confuses
(record and revert just that one).

---

### Phase B — Wave 0 hygiene: cheap additions and fixes

*(Prepared in parallel worktrees; merged sequentially in order E1 → E6.)*

---

#### DX-E1 — `Effect.sync_result` and `Effect.sync_option`

Phase B · Effort S · Risk low

**Problem.** The recommended leaf boundary is two combinators deep:
`Effect.sync (fun () -> Db.find id) |> Effect.flatten_result`. Correct
(exception → defect, `Error e` → typed failure, `Ok x` → success) and easy to
forget. The blocking path has the named form (`Eta_blocking.run_result`); the
sync path makes users assemble it by hand. The most common action in the
library should be one word.

**Proposal.**

```ocaml
val sync_result : (unit -> ('a, 'err) result) -> ('a, 'err) t
val sync_option : if_none:'err -> (unit -> 'a option) -> ('a, 'err) t
```

`sync_option` completes the symmetry: `from_result`/`from_option` for computed
values, `sync_result`/`sync_option` for thunks.

**Semantics & edges.** No new semantics — implemented as the composition they
name. `flatten_result` stays for hand-rolled cases; docs re-point the
recommended pattern. Doc budget ≤ 6 lines each (T8).

**Taste check.** T1, T3 (the name says where expected errors go), T4.

**Verification.** *Mechanical:* parity tests with `sync |> flatten_result`
incl. exception → `Die`; docs examples rewritten. *Review:* W1 walkthrough
(P-OCaml, P-ZIO); blind A/B of three call sites (DB lookup, file read,
parse). Pass bar: median ≥ 4; W1 solved without doc lookup in ≥ 2 of 3
persona passes. Sealed prediction required.

**Gates.** *Promote* on pass. *Kill/rename* if > 1/3 of persona passes expect
`sync_result` to also catch exceptions — the name would be teaching the wrong
defect model; try `attempt_result` and retest before abandoning.

**Alternatives.** Status quo (permanent tax on the hottest path).
`Effect.attempt` converting exceptions to typed failures (rejected per
`docs/zio-boundaries.md`).

---

#### DX-E2 — Fix the `Effect.ignore` footgun: `discard` + generalized `ignore_errors`

Phase B · Effort S · Risk low

**Problem.** `Effect.ignore` discards the success value **and suppresses typed
failures**. `Stdlib.ignore` suppresses nothing. P-OCaml will read
`eff |> Effect.ignore` as "run for effect, keep errors" and get silent
swallowing — the most misleading name in the surface (T2, T3 failure).

**Proposal.**

```ocaml
val discard : ('a, 'err) t -> (unit, 'err) t
  (* discard success value; ALL causes propagate unchanged *)
val ignore_errors : ('a, 'err1) t -> (unit, 'err2) t
  (* generalized from unit-only: discard value, suppress typed failures *)
```

Delete `Effect.ignore`; callers split into the two honest meanings
(compiler-guided).

**Semantics & edges.** `discard` is `map (fun () -> ())`. Generalizing
`ignore_errors` is source-compatible for correct uses and exposes misuses as
review points.

**Taste check.** T2 (invited bug disappears), T3, census: handle cluster −1.

**Verification.** *Mechanical:* migration; behaviour tests. *Review:*
teach-back — "what does `ignore_errors` do to defects?" — target: instant,
correct, from the name alone. Red-team: the swallowed-error bug must now
require the explicit `ignore_errors`.

**Gates.** *Promote* if teach-back improves vs. baseline. *Hold* only if
migration shows `ignore` was mostly value-discard — reassess naming, not the
split.

---

#### DX-E3 — `Effect.race_either`

Phase B · Effort S · Risk low

**Problem.** `race : ('a, 'err) t list -> ('a, 'err) t` needs a uniform
success type; heterogeneous races force `map`-wrapping both branches into a
common variant (T4 boilerplate around an unambiguous boundary).

**Proposal.**

```ocaml
val race_either :
  ('a, 'err) t -> ('b, 'err) t -> ([ `Left of 'a | `Right of 'b ], 'err) t
```

**Semantics & edges.** Same loser-cancellation and resource semantics as
`race`; the mli references `race`'s permit-acquisition caveat verbatim.

**Verification.** *Mechanical:* parity tests (winner value, loser
cancellation, finalizer runs). *Review:* blind A/B vs. the map-wrapped
version on timeout-vs-result and poll-vs-push snippets; median ≥ 4.

**Gates.** *Promote* on pass. *Kill* if reviewers find `` `Left/`` `Right ``
payloads harder to follow than named variants at call sites.

---

#### DX-E4 — `Cause` rendering: `pp_compact`, structured encoding, snapshot corpus

Phase B · Effort M · Risk low

**Problem.** `Cause.pretty` renders a multi-line tree, but: (a) no one-line
form exists for span statuses and log fields; (b) no structured encoding, so
sinks re-implement walks; (c) the tree rendering has no snapshot corpus — its
quality is unreviewed for the ugly cases (`Suppressed` × `Concurrent` ×
`Finalizer`, anonymous interrupts).

**Proposal.**

- Core: `Cause.pp_compact` — single line, e.g.
  `fail(Not_found) + interrupt | suppressed: finalizer(die(Unix.EPIPE))`.
- Structured encoding lives where JSON already lives: an
  `Eta_otel.Cause_json`-style encoder over `Cause.Portable.t`. Core stays
  JSON-free.
- Snapshot corpus: `pretty` + `pp_compact` for
  `Concurrent [Fail; Interrupt]`, `Suppressed { primary = Fail; finalizer = Die }`,
  nested `Finalizer (Sequential …)`, anonymous vs. identified interrupts,
  multi-defect composites.

**Taste check.** T6, T7, T8 (the corpus doubles as model documentation).

**Verification.** *Mechanical:* corpus as expect tests; `pp_compact` never
emits newlines (property). *Review:* error review board rates the corpus;
every composite must answer what/where/what-next without mli reading.

**Gates.** Pieces promote independently. *Kill* the one-liner if compactness
destroys the primary/finalizer distinction (board verdict) — two-line logs
are also a finding.

---

#### DX-E5 — Negative compile tests and an "Eta type errors, translated" page

Phase B · Effort S · Risk low

**Problem.** Scoped-handle safety relies on rank-2 types; the price is paid in
skolem-escape and quantification errors that are correct and unreadable.
Prior art: polysemy invests in library-owned error UX ("Fix: use `interpretH`
instead"); OCaml lacks GHC-style custom type errors, so Eta's levers are
PPX-time messages (fully controllable), cram snapshots, and a translation
page (T7).

**Proposal.**

- Cram-style negative compile tests capturing current messages for:
  `Supervisor` child-handle escape; resource-handle escape (where applicable);
  same-domain primitives (`Queue`/`Channel`/`Pubsub`/`Pool`) misused across
  `eta_par` domains; PPX rejection paths (already raised via
  `Location.raise_errorf` — review and snapshot their texts too).
- `docs/type-errors.md`: the 5–8 most common messages, each quoted verbatim
  from the snapshot, translated into what-you-tried / why-Eta-forbids / the
  two canonical fixes.

**Verification.** *Mechanical:* snapshots fail CI on message drift — forcing
the page to stay in sync. *Review:* W5 rigged to trigger the escape; reviewer
solves with and without the page; pass bar: with the page, the reviewer
explains the rank-2 rationale in their own words.

**Gates.** *Promote* unconditionally once the corpus lands; the by-product is
the list of messages needing compiler-side work.

---

#### DX-E6 — Parallel resource acquisition: recipe + `Effect.Scoped.with_2` / `with_3` (kills `and@`)

Phase B · Effort M · Risk low

**Problem.** Bootstrapping N independent resources becomes a ladder of nested
`let@ … = with_…` CPS inversion — correct, noisy, and serializing acquisitions
that could be parallel. A proposed `and@` operator would compose CPS resource
functions concurrently, which requires rendezvousing suspended continuations
across fibers — heavy machinery for a syntactic itch. The existing algebra
already solves it: `acquire_release` registers into the enclosing scope,
`map_par`/`all` parallelizes acquisition, scope exit releases in reverse
order on success, failure, defect, and cancellation.

**Proposal.** Document the recipe, then give it one obvious spelling:

```ocaml
module Scoped : sig
  val with_2 :
    acquire1:('a, 'err) t -> release1:('a -> (unit, 'r1) t) ->
    acquire2:('b, 'err) t -> release2:('b -> (unit, 'r2) t) ->
    ('a -> 'b -> ('c, 'err) t) -> ('c, 'err) t
  val with_3 : (* same shape *)
end
```

Acquisition concurrent and fail-fast; a failed acquire leaves the scope to
release whatever was already registered; reverse-order release inherited from
the scope. Arity > 3 = hand-rolled recipe (progressive disclosure, not an
arity zoo).

**Semantics & edges.** Partial-acquire failure: registered releases still run
at scope exit — this is the core test. Note: lands after DX-E25, so the
recipe uses `with_scope` spelling.

**Taste check.** T1 (one spelling), T4 (composition of decided semantics, no
new machinery), T8 (recipe + two helpers replace an operator and its
semantics section).

**Verification.** *Mechanical:* partial-failure release, release order,
second-acquire failure, parity with nested `with_resource`. *Review:*
bootstrap task (3 resources) ladder vs. `with_3`; blind A/B + screenshot
test; teach-back: "second acquire fails — what happens?"

**Gates.** *Promote* if inferred error rows stay readable in review
artifacts. *Kill* the helpers (keep the recipe) if `with_3`'s labelled
boilerplate rates worse than the ladder. **`and@` is killed by this
experiment's existence** — record `V-DX-E6` as the evidence.

---

### Phase C — Wave 1 syntax & PPX (after Phase A names settle)

---

#### DX-E7 — Error-renderer deriver in `ppx_eta` (generates `pp_err`)

Phase C · Effort M · Risk low

**Problem.** Typed failures render as `"<typed failure>"` in span statuses and
exception events unless every module hand-writes a renderer — so the default
telemetry is uninformative exactly where it should help most (T6). After
DX-E25 the injection socket is `?error_pp`, matching OCaml's `pp` culture;
the remaining gap is that nobody writes the `pp`.

**Proposal.** A `ppx_eta` deriver, strictly syntactic (T9):

```ocaml
type err =
  [ `Not_found of string
  | `Db of int
  | `Unavailable ]
[@@deriving eta_error]
```

expands to a review-acceptable plain function (T4):

```ocaml
let pp_err : Format.formatter -> err -> unit = fun fmt -> function
  | `Not_found id -> Format.fprintf fmt "not_found:%s" id
  | `Db code -> Format.fprintf fmt "db:%d" code
  | `Unavailable -> Format.pp_print_string fmt "unavailable"
```

v1 scope: polymorphic variants only; built-in payload renderers for
`string`, `int`, `int64`, `float`, `bool`; any other payload is a **PPX-time
error** unless the constructor carries `[@eta.render f]` naming a `pp` — no
silent `<payload>` placeholders (placeholders are how `"<typed failure>"`
reproduces). Nominal variants only if they keep the same plain-match shape.

Usage: `Effect.named ~error_pp:pp_err "db.save" …`, or one
`Effect.with_error_pp pp_err` per module subtree.

**Semantics & edges.** None — pure generation. Rendered strings are stable
telemetry: renaming a tag changes dashboards; documented as honest and
visible.

**Taste check.** T6 (meaningful defaults become the path of least
resistance), T4/T9 (expansion is code a reviewer would write), T11 (same
shape as `[@@deriving show]` output).

**Verification.** *Mechanical:* expansion snapshots for supported shapes;
PPX-time rejection snapshots for unsupported payloads; golden span-status
test with the in-memory tracer; census of `examples/`+`docs/` error types —
renderer coverage target 100%. *Review:* error review board reads real span
output before/after; blind rating of telemetry excerpts.

**Gates.** *Promote* if coverage hits 100% without hand-written renderers
remaining in examples. *Kill* if the payload long tail forces the deriver
past "plain match you would approve in review" — then the honest answer is
manual `pp` + better docs, not a smarter PPX.

**Alternatives.** Recommend `[@@deriving show]` directly (rejected: pulls a
formatting framework into telemetry and renders constructor noise not meant
for span statuses). Docs exhortation (rejected: that is the status quo).

---

#### DX-E8 — `[%eta.result "name" body]` leaf sugar

Phase C · Effort S (after DX-E1) · Risk low

**Problem.** The named-leaf pattern is fully mechanical:
`Effect.fn __POS__ __FUNCTION__ (Effect.named "db.find" (Effect.sync …))`.
`ppx_eta` already proves it with `[%eta.sync "name" body]`. With DX-E1 the
result-returning leaf is the same shape with `sync_result` — and without
sugar it stays the most frequently typed boilerplate in the library.

**Proposal.** Extend the existing `expand_sync_like` path:

```ocaml
let user = [%eta.result "db.find" (Db.find db id)]
(* expands to *)
Effect.fn __POS__ __FUNCTION__
  (Effect.named "db.find" (Effect.sync_result (fun () -> Db.find db id)))
```

`[%eta.option "cache.get" ~if_none:`Missing expr]` only if DX-E1 usage data
shows `sync_option` is actually common; otherwise skip — sugar follows
demonstrated frequency (T4), not symmetry.

**Semantics & edges.** Inherits DX-E1's channel semantics; the PPX adds span
naming and location, nothing else (T9).

**Verification.** *Mechanical:* expansion snapshots; parity with the
hand-written form. *Review:* operators per leaf boundary across `examples/`
before/after; screenshot test on the heaviest module.

**Gates.** *Promote* with DX-E1. *Kill* the day the expansion needs
explaining.

---

#### DX-E9 — Make concurrency explicit: `Syntax.Parallel` vs. `Syntax.Applicative`

Phase C · Effort M · Risk med (breaking; batched with Phase A changelog)

**Problem.** `and*` currently means *run concurrently and bind both* — and
nothing at the call site says fibers are forked and the sibling is cancelled
on failure. ppx_let users expect `and*` to be whatever the applicative is —
often sequential. The semantics are fine; their visibility is not (T2).

**Proposal.** Split the applicative operators out of the always-open module:

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

The `open` becomes a reviewable declaration of intent. Sequential applicative
composition (two DB writes, order-sensitive validations) gets a home it does
not have today.

**Semantics & edges.** `Parallel` = today's `and*`/`and+` (`par`).
`Applicative` = `let* a = x in let+ b = y in (a, b)` — strict left-to-right,
fail-fast by sequencing, nothing forked. Migration is compiler-guided;
changelog documents it (one release, no shim).

**Verification.** *Mechanical:* law tests for both modules. *Review:*
guess-the-semantics — `let* x = a and* y = b in …` under each open; ask: how
many fibers? what happens when `a` fails? Target ≥ 80% accuracy with the
explicit module vs. baseline measured on the implicit form. Sealed prediction
required: if the explicit form does not beat baseline materially, the split
is ceremony — kill it.

**Gates.** *Promote* on a real comprehension delta. *Kill* if baseline is
already ≥ 80%.

---

#### DX-E10 — Function-level `let%eta` / `[@@eta.trace]`

Phase C · Effort M · Risk med · **default state: hold**

**Problem.** `Effect.fn __POS__ __FUNCTION__` wrapping is mechanical but
visually heavy at the definition site. `let%eta f x = body` →
`let f x = Effect.fn __POS__ __FUNCTION__ body` is attractive — and is also
the first PPX that changes the shape of a *definition*, the step where sugar
starts to read like behaviour.

**Proposal.** Experiment only: wraps the body's result position (after all
labeled/optional arguments); `let rec` allowed (wrapper inside); expansion
stays one line. Choose one spelling (`let%eta` or `[@@eta.trace]`) after
review, not both.

**Semantics & edges.** Type errors in the body point into generated code —
the known cost; mitigated by minimal expansion and docs. `.mli` signatures
unchanged (wrapper is representation-level) — verify explicitly.

**Verification.** *Mechanical:* expansion snapshots for labeled/optional/rec
shapes; error-message snapshot for a mistyped body, rated by the error board.
*Review:* A/B a real converted module; reviewers rate both versions cold.
Sealed prediction: authors like it, reviewers neutral-to-negative.

**Gates.** *Hold by default* even on success: land DX-E7/E8 first, promote
only if reviewers still ask afterward. *Kill* if generated-code error
locations rate ≤ 3 and cannot be improved.

---

### Phase D — Wave 2 runtime & model

---

#### DX-E26 — `Effect.fresh` (imported from fused-effects `Fresh`)

Phase D · Effort S · Risk low · warm-up for the phase

**Problem.** Fiber names, span-correlation ids, and test fixtures need unique
tokens; today each module rolls its own counter or abuses `Random`.
fused-effects ships a minimal `Fresh` effect for exactly this; the need is
real and the surface is one leaf.

**Proposal.**

```ocaml
val fresh : unit -> (int, 'err) t
val fresh_named : string -> (string, 'err) t  (* "worker-7" from prefix *)
```

Runtime-owned monotonic counter capability; per-runtime uniqueness, no
cross-domain guarantees beyond that (documented). Deterministic under
`Eta_test` (counter resets with the test runtime).

**Semantics & edges.** Zero allocation beyond the counter; thread-safe on the
runtime substrate. jsoo: plain mutable cell per runtime — portable (T10).

**Verification.** *Mechanical:* monotonicity, uniqueness under `par`,
test-runtime determinism. *Review:* call-site rating; census +1 justified.

**Gates.** *Promote* unless the review finds `Random`-based DIY adequate —
record the evidence either way (imported from fused-effects; cite
`Control.Effect.Fresh`).

---

#### DX-E19 — Scoped capability override: `with_clock` / `with_random` / `with_logger` / `with_tracer`

Phase D · Effort M · Risk med · **flagship import (polysemy `reinterpret` in Eta's idiom)**

**Problem.** polysemy's killer move is local reinterpretation: mock one
effect into simpler ones inside a single subtree, leaving the rest of the
program untouched. Eta's analogue of "the effect" for runtime services is
interpreter configuration — currently settable only at `Runtime.create`, so a
fake clock for one test means constructing a whole test runtime. Eta already
owns the machinery for the idiomatic version: `annotate_logs`,
`with_minimum_log_level`, `with_context`, `with_error_pp` are fiber-local
dynamic bindings. Generalizing them to the four runtime capabilities is the
same pattern applied to its natural home. Crucially, `zio-boundaries.md`
rejects ambient fiber-local state *"unless Eta owns a clear invariant"* —
runtime services are exactly that invariant: this never touches application
dependencies, so it is not `R` through the back door.

**Proposal.**

```ocaml
val with_clock  : Capabilities.clock  -> ('a, 'err) t -> ('a, 'err) t
val with_random : Capabilities.random -> ('a, 'err) t -> ('a, 'err) t
val with_logger : Capabilities.logger -> ('a, 'err) t -> ('a, 'err) t
val with_tracer : Capabilities.tracer -> ('a, 'err) t -> ('a, 'err) t
```

Fiber-local, dynamically scoped; consulted by the corresponding leaves
(`now_ms`/`sleep`/`delay`/`timed`/`timeout*`/`retry`/`repeat` for clock;
`Random.*`; `log*`; `named`/`fn` spans). Test DX: a fake clock scoped to one
assertion instead of a bespoke runtime —
`Effect.with_clock (Test_clock.as_capability c) program`.

**Semantics & edges (the substance).**

- *Inheritance:* children inherit the binding at fork (like `annotate_logs`);
  no join-merge; restore on exit, typed failure, defect, and cancellation.
- *Composition (fused-effects' lesson: handler order is semantics):*
  innermost binding wins; nesting and sibling isolation rules written into
  the mli and the docs, with examples — `par` branches must not leak
  overrides into each other (test).
- *Interplay:* `with_logger` replaces the sink; `annotate_logs` (attrs) and
  `with_minimum_log_level` (filter) are orthogonal and compose; DX-E20's
  `intercept_log` transforms before the sink — the order is documented.
- *jsoo (T10):* overrides are pure data swaps over fiber-local cells; the
  jsoo runtime already has fiber-local context — portable.

**Taste check.** T1 (one way to fake a capability), T9 (explicit value, no
magic), and the census stays flat: four bindings replace the ad-hoc pattern
of threading test configuration through runtime constructors.

**Verification.** *Mechanical:* restore-on-failure/defect/interrupt;
fork-inherit; sibling isolation under `par`; clock override observed by
`sleep`/`timeout`; composition-order tests. *Review:* W6 rewritten both ways
(test-runtime vs. scoped override), blind A/B; teach-back: "where does the
fake clock stop applying?"

**Gates.** *Promote* if the semantics fit the doc budget and the otel
interplay stays unambiguous. *Kill* if either grows a paragraph of caveats —
that would mean fiber-local overrides are a second configuration system, and
Eta should keep constructors only. Import provenance: polysemy
`reinterpret`/`local`; record in the journal.

---

#### DX-E20 — `Effect.intercept_log` / `intercept_metric` (imported from polysemy `intercept`)

Phase D · Effort M · Risk low–med

**Problem.** polysemy's `intercept` interposes on an effect: observe or
transform its calls without replacing the implementation. Eta already has
two private cases of that shape — `annotate_logs` (enrich) and
`with_minimum_log_level` (filter) — as ad-hoc combinators. The general form
unifies them and unlocks redaction, sampling, and record-and-assert testing.

**Proposal.**

```ocaml
val intercept_log :
  (Capabilities.log_record -> Capabilities.log_record option) ->
  ('a, 'err) t -> ('a, 'err) t
val intercept_metric :
  (metric -> metric option) -> ('a, 'err) t -> ('a, 'err) t
```

`None` drops the record. `annotate_logs attrs` and
`with_minimum_log_level lvl` remain as the two friendly special cases
(progressive disclosure: common tasks keep one-word answers; the general
mechanism serves power users). Redaction composes with `eta_redacted`:
`intercept_log (Redacted.scrub_record)`.

**Semantics & edges.** Transforms compose outermost-to-innermost; `None`
short-circuits. Order vs. sinks: intercept runs before the logger/meter;
order vs. DX-E19 overrides documented (transform applies to whatever sink is
currently bound). Hot-path cost: one function call per record, documented;
no allocation when the transform is `Some`-identity (fast path).

**Taste check.** T1 (one concept: interception; two shorthands for the common
cases), T6 (redaction becomes a mechanism, not a discipline).

**Verification.** *Mechanical:* composition order; drop semantics; fast-path
benchmark line in `bench/`; parity tests that the shorthands behave exactly
as before. *Review:* blind A/B of a redaction and a sampling snippet vs.
today's discipline-based approach; teach-back: "which combinator drops
records?"

**Gates.** *Promote* if shorthands' parity is exact and hot-path cost is
noise-level on the watchlist. *Kill* the metric half if nobody can write a
compelling `intercept_metric` use case in review (the log half stands on its
own). Import provenance: polysemy `intercept`.

---

#### DX-E11 — `Eta_test.run`: one golden-record test runtime

Phase D · Effort L · Risk med · prior art: polysemy `runOutputMonoid` — *run an effect into data*

**Problem.** The hard questions in an effect system are not about the result:
*was the sibling cancelled? did the finalizer run? did retry sleep 10, 20,
40? is any fiber still pending? was the suppressed failure preserved?* Today
they require assembling `Test_clock`, `with_logger`, `with_tracer`,
`Async.fork_run`, and `Expect` by hand — and pending fibers / finalizer
events have no public answer at all.

**Proposal.** One entry point returning one inspectable record:

```ocaml
module Eta_test.Run : sig
  type ('a, 'err) outcome = {
    exit             : ('a, 'err) Exit.t;
    logs             : Eta.Logger.record list;
    spans            : Eta.Tracer.span list;
    metrics          : (* meter updates *) ;
    sleeps           : Duration.t list;        (* observed, in order *)
    pending_fibers   : fiber_info list;        (* NEW: runtime accounting *)
    finalizer_events : finalizer_event list;   (* NEW: runtime accounting *)
  }
  val run : ?clock:Test_clock.t -> ?seed:int -> … -> ('a,'err) Effect.t -> ('a,'err) outcome
  val expect_no_pending_fibers : _ outcome -> unit
  val expect_sleeps            : Duration.t list -> _ outcome -> unit
  val expect_finalizers        : int -> _ outcome -> unit
end
```

- `sleeps` comes from the virtual clock: backoff asserted exactly, no wall
  time.
- `pending_fibers` / `finalizer_events` need opt-in runtime accounting (a
  fiber registry and finalizer journal, test-runtimes only; production cost
  must stay zero — feasibility is the first question; `Runtime.drain` already
  accounts daemon work and is the seam to generalize).
- The record is golden: `Alcotest.testable`s and a printer so a failure
  prints the whole execution, not a boolean. After DX-E19, `run`'s optional
  overrides can delegate to scoped bindings internally.

**Semantics & edges.** Deterministic by construction. Accounting must not
change scheduling — verified by running the existing suite under an
accounting runtime and diffing exits.

**Verification.** *Mechanical:* golden tests for six canonical scenarios —
sibling cancelled on failure; finalizer ran on interruption; retry slept
[10; 20; 40]; span closed on defect; suppressed finalizer preserved;
race-loser resource released; accounting-neutrality check. *Review:* W6 with
today's assembly vs. one call — time-to-green target: halves; failure output
of a deliberately broken test rated on the message rubric.

**Gates.** *Promote* the record even if accounting slips (exit+logs+spans+
sleeps already wins). *Kill* `pending_fibers` specifically if it cannot be
test-only/zero-cost — recorded as a runtime design finding. *Kill* the whole
if the golden printer is unreadable at corpus size.

---

#### DX-E12 — `Effect.audit` and `Effect.describe`: blueprint introspection

Phase D · Effort M · Risk low

**Problem.** Two needs are met by prose and discipline: teaching
("an `Effect.t` is a blueprint; `Runtime.run` interprets it") and
verification ("this handler never sleeps"). The blueprint is already reified
(`collect_names` traverses it); the introspection is just not exposed. The
fused-effects docs teach the same dichotomy as syntax-vs-semantics
(algebra/carrier) — `describe` gives Eta's tutorial the same backbone (T11
pedagogy import).

**Proposal.**

```ocaml
type audit = {
  names           : string list;
  uses_clock      : bool;  emits_logs : bool;  emits_metrics : bool;
  has_concurrency : bool;  has_resources : bool; has_background : bool;
}
val audit    : ('a, 'err) t -> audit
val describe : ('a, 'err) t -> string  (* static tree; unforced continuations
                                          printed as <bind …> *)
```

Plus `Eta_test` assertions: `assert_no_clock`, `assert_pure_eff`, … — the
vocabulary docs already use, made executable (T5). Static preflight, **not** a
runtime inventory: continuation nodes are not forced; flags are conservative
and the docs say which way each can err.

**Verification.** *Mechanical:* property tests — flags consistent with
execution (`uses_clock = false` ⇒ runs against a poisoned clock);
`describe` snapshot corpus; audit of every `examples/` program as golden
files (a machine-generated requirements manifest — the useful 80% of a
proposed annotation system, zero drift). *Review:* teaching session — the
blueprint model from `describe` output vs. from prose; teach-back scored.

**Gates.** *Promote* on green properties + tutorial rating ≥ 4. *Kill*
`audit`'s manifest role if example flags mislead more than inform — evidence
feeds DX-E17.

---

#### DX-E13 — `Effect.async`: the missing algebra leaf

Phase D · Effort M–L · Risk med (two-substrate semantics)

**Problem.** No constructor exists for callback-shaped effects. Wrapping an
event emitter, a host timer, a JS `Promise`, or a C callback means dropping
to `Expert.make` — a runtime-package escape hatch — for application-level
work. ZIO has `effectAsync`; polysemy ships `Async`; the js_of_ocaml track
lives on callbacks.

**Proposal.**

```ocaml
val async :
  register:((('a, 'err) Exit.t -> unit) -> (unit, 'err) t option) ->
  ('a, 'err) t
```

One-shot resolution (later calls dropped, documented); optional canceler run
uninterruptibly on interruption; `register` raising → `Cause.Die`;
synchronous resolution during registration must not deadlock; no lost wakeup
between registration and parking (specify and test). jsoo paragraph (T10):
maps naturally onto the CPS-based JS runtime; host capabilities checked
loudly, never polyfilled (ADR 0001 discipline).

**Verification.** *Mechanical:* resolve-once; canceler-runs-on-interrupt;
canceler-uninterruptible; register-raises → `Die`; sync-resolve no-deadlock;
no lost wakeup under cancel racing registration (seeded interleavings where
possible); same suite both backends. *Review:* wrap-`addEventListener` on
jsoo vs. the `Expert.make` version, blind A/B; teach-back of the canceler
contract.

**Gates.** *Promote* only if both substrates implement the full contract;
otherwise *hold* with the divergence recorded — a core primitive with two
meanings is worse than none (T10). *Kill* if the lost-wakeup guarantee cannot
be stated and tested cleanly on either backend.

---

#### DX-E14 — `Eta.Promise`: a backend-neutral one-shot cell

Phase D · Effort M · Risk med

**Problem.** Docs direct users to `Eio.Promise` — pinning application code to
the native substrate, and the choice has already leaked into the public test
API (`Eta_test.Async` re-exports `Eio.Promise.t`). Eta's own wrap rule
(AGENTS.md H-W4) lists *portability fences* as a reason to wrap; the trigger
is a second backend needing a one-shot cell — DX-E13 and real jsoo programs.

**Proposal.**

```ocaml
module Eta.Promise : sig
  type ('a, 'err) t
  val create  : unit -> ('a, 'err) t
  val await   : ('a, 'err) t -> ('a, 'err) Effect.t
  val resolve : ('a, 'err) t -> ('a, 'err) Exit.t -> (bool, 'outer) Effect.t
end
```

`await` cancellation-safe (waiter removal, never consumes the resolution);
scope/boundary close interrupts remaining awaiters; one-shot (`false` on
repeat resolve). `Eio.Promise` remains right for Eio-only code — this is a
fence, not a takeover (documented, same posture as the Eio-primitives table).

**Verification.** *Mechanical:* single-resolution; N awaiters wake; cancelled
waiter does not consume; boundary close interrupts waiters; parity on both
backends. *Review:* coordinate two fibers in the jsoo track — impossible
today without `Expert`; rate the resulting code.

**Gates.** *Promote* when E13 or a jsoo example consumes it. *Hold* until
then — building it speculatively violates the discipline that keeps wrappers
rare. *Kill* if the two backends cannot share cancel-and-close semantics.

---

### Phase E — Wave 3 research (pre-registered kill criteria)

---

#### DX-E22 — Law-property test policy (imported from fused-effects' hedgehog culture)

Phase E (may run any time after Phase A) · Effort M · Risk low

**Problem.** Eta's mli files state contracts in prose ("release runs on
success, failure, defect, and cancellation"; "par is fail-fast"). fused-effects
enforces a harder rule: every law stated in the documentation has a
generative test. The mli is where users learn the model; untested prose is
where models drift.

**Proposal.** Adopt the policy **"every law in an mli has a qcheck test"**,
bootstrapped with an initial law inventory:

- monad-ish laws: `map id`, `map f ∘ map g`, `bind` associativity, `pure`/`bind`;
- error channel: `bind_error` left-identity, `fold` coherence with
  `map`/`bind_error`;
- concurrency: `par` result pair-order, fail-fast cancels sibling, `map_par`
  preserves input order under interleavings, `race` loser cancellation;
- lifecycle: `finally` runs exactly once on each exit kind; scope LIFO;
  `with_resource` release on all exits;
- primitives: `Channel` close fences, `Semaphore` cancellation safety,
  `Queue` close/error ordering;
- schedules: monotone delays, `recurs n` step count;
- E19/E20 if promoted: override restore, sibling isolation, intercept order.

Deliverables: qcheck suite + a policy paragraph added to AGENTS.md /
contributing docs + a census of laws-per-mli as a tracked number.

**Verification.** The suite is the verification. *Review:* maintainer-grade —
does the law list read like the model? Gaps found become footgun entries.

**Gates.** *Promote* when the initial inventory is covered and the policy
paragraph lands. Provenance: fused-effects README testing discipline.

---

#### DX-E15 — `Effect.interruptible`: restoring cancellation inside masks

Phase E · Effort M · Risk high (cancellation semantics)

**Problem.** `uninterruptible` is one-way; there is no `restore` to re-enable
cancellation inside a masked region. Canonical victims are library-shaped:
an uninterruptible accept loop that must block *interruptibly*; a cleanup
that itself awaits. Today inexpressible without dodging the mask.

**Proposal.**

```ocaml
val interruptible : ('a, 'err) t -> ('a, 'err) t
(** Re-enable parent cancellation within a dynamically enclosing
    [uninterruptible]. Masks stack; interruption is delivered at the first
    interruptible point. Outside any mask: identity. *)
```

**Semantics & edges (the substance).**

- Cancellation checkpoints (`yield`, `sleep`, blocking awaits) must become
  documented API — today implicit. The experiment forces the checkpoint list
  into docs: a DX win even if the combinator dies.
- `interruptible` inside a finalizer: decide explicitly (ZIO says no); record
  Eta's answer and its reason.
- Mask-stack laws: `uninterruptible (interruptible (uninterruptible e))` ≡
  `uninterruptible e`; delivery at most once; no lost wakeup when cancel
  races mask entry — property-tested against Eio (`Cancel.protect`
  composition), jsoo meaning stated (T10).

**Verification.** *Mechanical:* laws as properties; race corpus (cancel-
during-mask-entry, cancel-at-checkpoint, nested masks) on both backends.
*Review:* P-Maint-grade — reviewed docs section + a real accept loop written
against it; red-team tries to lose a cancellation.

**Gates.** *Promote* only with the checkpoint list published and laws green
on both substrates. *Kill* if the semantics cannot be stated within the doc
budget — inexpressible-in-docs cancellation is worse than none.

---

#### DX-E16 — `Reader`: a validation experiment for the no-`R` decision

Phase E · Effort S · Risk low (by construction: core untouched)

**Problem.** Eta bets that value-passing beats an environment parameter —
defended by reasoning and ZIO's HList scars, not by an in-repo comparison.
The honest defence is to build the rival and race it.

**Proposal.** A ~50-line optional module (branch or `eta_reader`):

```ocaml
module Reader : sig
  type ('env, 'a, 'err) t = 'env -> ('a, 'err) Effect.t
  val ask   : ('env, 'env, 'err) t
  val local : ('env -> 'env) -> ('env, 'a, 'err) t -> ('env, 'a, 'err) t
  val map   : ('a -> 'b) -> ('env, 'a, 'err) t -> ('env, 'b, 'err) t
  val bind  : ('a -> ('env, 'b, 'err) t) -> ('env, 'a, 'err) t -> ('env, 'b, 'err) t
end
```

The race: port one real `examples/` service twice — value-passing vs.
`Reader` — and compare with sealed predictions: diff size and shape; inferred
types on hover; error messages on a wrong env record; reviewer comprehension
and teach-back; and the "one big env blob" drift check (does the Reader
version sprawl within one service?).

**Gates.** *Promote* as an optional package only if Reader wins on
pre-registered criteria. *Kill* — the expected outcome — with diff and
ratings as `V-DX-E16`: the no-`R` boundary then rests on in-repo evidence,
not taste. Either way the boundary becomes *tested*.

---

#### DX-E21 — Resumable-failure probe (fused-effects `Resumable`), `.scratch` only

Phase E · Effort S (timeboxed: 1 day) · Risk: contained by construction

**Problem.** fused-effects ships resumable exceptions: catch, inspect, resume
at the throw point. Under Eta's hood are OCaml 5 effect handlers — delimited
continuations are physically available, so the probe is cheap. But resumption
is a cousin of `catchAllCause` (rejected in `zio-boundaries.md`), and a
resumed computation that outlives its scope is a designed resource leak.

**Proposal.** No public API. A `.scratch/research/e21-resumable/` probe
answering one question: *can a subtree that failed with a typed `Fail` be
resumed with a replacement value, without the `Cause` tree lying about what
happened?* Deliverable is a journal report (`V-DX-E21`) with a promote-to-
experiment or kill recommendation.

**Pre-registered kills:** (a) resumption requires exposing continuation
machinery that conflicts with the no-`catchAllCause` boundary; (b) resumption
can outlive the enclosing `with_scope`; (c) the `Cause` tree cannot represent
resumed-then-succeeded executions honestly. Any one fires → kill, and the
report becomes the evidence.

**Value even when killed:** the report pins down what Eta's model *forbids*
and why — a boundary doc entry money cannot buy.

---

#### DX-E17 — Runtime-capability phantom rows

Phase E · Effort L · Risk high · **entry gate: DX-E12 promoted + audit data showing real integration bugs**

**Problem.** `('a, 'err) Effect.t` cannot say whether a blueprint needs a
clock, concurrency, or blocking; integration bugs surface at runtime. A
phantom row `('a, 'err, 'caps) Effect.t` over a **closed** set
(`` `Clock ``, `` `Concurrency ``, `` `Blocking `` — interpreter requirements,
never application services) could make them compile-time.

**Why the gate.** Rows in infer-and-join positions are a known ambush: every
combinator must join rows; inferred types grow; unification errors degrade.
DX-E12's `audit` already delivers the cheap 80% (static preflight, test
assertions, generated manifests). The row is justified only if audit data
shows bugs the preflight class cannot catch.

**Proposal (branch-only).** Prototype the row on ~10 representative modules;
public `Effect.t` untouched. Pre-registered measurements: inferred type size
per module; error-board rating of missing-capability messages vs. today's
runtime failure; count of combinators needing > 0 new type parameters;
migration cost per module.

**Gates.** *Kill* if any combinator needs > 1 new type parameter, if corpus
messages rate worse than the runtime-failure baseline, or if the closed set
drifts toward application services (the `R` slippery slope). *Promote* only
as an opt-in parallel module, never an arity change to `Effect.t`.

---

#### DX-E18 — Deterministic simulation testing

Phase E · Effort L · Risk med · **framing: maintainer tooling, not user API**

**Problem.** Eta has halves of deterministic testing — `Test_clock`, seeded
`Test_random` — but fiber interleaving is host-scheduled, so concurrency bugs
are found by luck and reproduced by prayer. The repo's culture (red probes,
CVE regressions, h2spec) says adversarial reality belongs in the suite.

**Proposal.** A simulation runtime for tests: a single-domain scheduler
interleaving ready fibers by seeded RNG at documented checkpoints (yield,
sleep-expiry, channel ops, promise resolution), seed printed on failure for
byte-identical replay. Scope: `Effect` subset only — no `eta_par` domains, no
real I/O (faked at the capability seam).

**Verification.** *Mechanical:* replay-identity property (same seed ⇒ same
exit, same event order) across the core suite; a found-bugs log — every real
bug recorded with its seed as permanent evidence. *Review:* P-Maint rating of
failure output (seed + interleaving trace must be readable).

**Gates.** *Promote* when it finds its first real bug — that is the entire
argument. *Kill/hold* if, after a fixed exploration budget, it finds only
reproductions of known behaviors — evidence the checkpoint set is wrong or
the payoff illusory.

---

## 6. Status dashboard

The executing agent updates this table (and its copy in the journal header)
after every experiment. Status: `proposed` / `in-progress` / `promoted` /
`held` / `killed`. `SC` = flagged for later human spot-check (§4.5 rule 4).

| ID | Title | Phase | Effort | Risk | Status | SC | Branch | Evidence |
|----|-------|-------|--------|------|--------|----|--------|----------|
| E23 | Error channel mirrors Result | A | M | low | **promoted** 2026-07-18 | SC | research/dx-e23-result-error-channel | V-DX-E23-001..002 |
| E24 | Iteration mirrors List; slim Schedule | A | M | low-med | **promoted** 2026-07-18 (slimming held → E24b) | SC | research/dx-e24-iteration-mirrors-list | V-DX-E24-001..004 |
| E24b | Schedule-hook ownership decision | E | S-M | contained | **promoted** 2026-07-23 (deletion proposed → E24c) | | research/dx-e24b-hook-ownership | V-DX-E24B-001..002 |
| E25 | Family consistency renames | A | S-M | low | **promoted** 2026-07-18 | SC | research/dx-e25-family-consistency | V-DX-E25-001..002 |
| E1 | sync_result / sync_option | B | S | low | **promoted** 2026-07-18/20 (sync_option reversal by human authority) | SC | research/dx-e1e2e3-hygiene | V-DX-E1-001..004 |
| E2 | discard / ignore_errors | B | S | low | **promoted** 2026-07-18 | SC | research/dx-e1e2e3-hygiene | V-DX-E2-001..002 |
| E3 | race_either | B | S | low | **killed** 2026-07-18 | SC | research/dx-e1e2e3-hygiene | V-DX-E3-001..002 |
| E4 | Cause rendering corpus | B | M | low | **promoted** 2026-07-19 (kill gate fired; rework passed) | SC | research/dx-e4e5-cause-corpus-type-errors | V-DX-E4-001..002 |
| E5 | Type-error translations | B | S | low | **promoted** 2026-07-19 | SC | research/dx-e4e5-cause-corpus-type-errors | V-DX-E5-001..002 |
| E6 | Scoped.with_2/3 (kills and@) | B | M | low | **killed** (helpers) · recipe promoted 2026-07-19 | SC | research/dx-e6-scoped-with-helpers | V-DX-E6-001..002 |
| E7 | Error-pp deriver | C | M | low | **promoted** 2026-07-19 | SC | research/dx-e7-error-pp-deriver | V-DX-E7-001..002 |
| E8 | [%eta.result] sugar | C | S | low | **promoted** 2026-07-19 | SC | research/dx-e8-eta-result-sugar | V-DX-E8-001..002 |
| E9 | Syntax.Parallel/Applicative | C | M | med | **held** 2026-07-19 (baseline 2/6, explicit 2/6) | SC | research/dx-e9-syntax-parallel-applicative | V-DX-E9-001..002 |
| E9b | Honest and* (sequential); Effect.par | C | S-M | low-med | **promoted** 2026-07-19 | SC | research/dx-e9b-honest-and-star | V-DX-E9B-001..002 |
| E10 | let%eta function sugar | C | M | med | **held** 2026-07-19 (let%eta killed; [@@eta.trace] pre-selected) | SC | research/dx-e10-function-sugar | V-DX-E10-001..002 |
| E26 | Effect.fresh | D | S | low | **promoted** 2026-07-20 | SC | research/dx-e26-effect-fresh | V-DX-E26-001..002 |
| E19 | Scoped capability override | D | M | med | **promoted** 2026-07-20 | SC | research/dx-e19-scoped-capability-override | V-DX-E19-001..002 |
| E20 | intercept_log/metric | D | M | low-med | **promoted** 2026-07-21 (as E20b variant repr) | SC | research/dx-e20-intercept | V-DX-E20-001..002, V-DX-E20B-001..002 |
| E11 | Eta_test.run golden record | D | L | med | **promoted** (finalizer_events killed) 2026-07-21 | SC | research/dx-e11-test-run | V-DX-E11-001..002 |
| E12 | audit / describe | D | M | low | **promoted** (API; manifest role killed) 2026-07-21 | SC | research/dx-e12-audit-describe | V-DX-E12-001..002a |
| E13 | Effect.async | D | M-L | med | **promoted** 2026-07-22 | | research/dx-e13-effect-async | V-DX-E13-001..002 |
| E14 | Eta.Promise | D | M | med | **promoted** 2026-07-22 | | research/dx-e14-eta-promise | V-DX-E14-001..002 |
| E22 | Law-property policy | E (flex) | M | low | **promoted** 2026-07-23 | | research/dx-e22-law-properties | V-DX-E22-001..002 |
| E15 | interruptible / restore | E | M | high | proposed | | | |
| E16 | Reader validation race | E | S | low | proposed (expected kill) | | | |
| E21 | Resumable probe (.scratch) | E | S | contained | proposed (expected kill) | | | |
| E17 | Capability phantom rows | E | L | high | proposed (gated) | | | |
| E18 | Simulation testing | E | L | med | proposed | | | |

## 7. Execution order and phasing

```text
Phase A (idiom pass; strictly sequential; one changelog entry)
  E23 → E24 → E25
Phase B (hygiene; parallel worktrees OK, sequential merge)
  E1 → E2 → E3 → E4 → E5 → E6
Phase C (syntax & PPX; E7/E8/E10 share ppx_eta.ml — never concurrent)
  E7 → E8 → E9 → E10 (hold default)
Phase D (runtime & model)
  E26 → E19 → E20 → E12 → E11 → E13 → E14
Phase E (research; E22 may run any time after Phase A)
  E22 → E15 → E16 → E21 → E17 (gated on E12) → E18
```

Ordering logic:

1. **Names before additions.** Phase A renames the surface so every later
   experiment builds on final spellings — additions in Phase B+ never need
   renaming twice.
2. **Constructors before sugar.** PPX (E7, E8, E10) expands into Phase A/B
   primitives (`sync_result`, `error_pp`, `Effect.fn`); sugar must not bake
   pre-rename shapes into generated code.
3. **Breaking changes batched.** Phase A + E2 + E9 renames land in one
   changelog entry ("idiom pass"); the changelog is the migration guide
   (AGENTS.md rule).
4. **Runtime after the model settles.** Phase D instruments or extends the
   interpreter; it should not race surface churn.
5. **Research behind entry gates.** E17 requires E12 evidence; E14 requires
   E13 or concrete jsoo pull; E21 is timeboxed; E16 is a race designed to be
   lost cleanly.
6. **Cheap taste signals first within each phase** — the methodology itself
   gets debugged on low-stakes experiments before it gates expensive ones.

Suggested first session: E23 alone, end-to-end, including journal, review,
and dashboard — it exercises the entire protocol on the most mechanical
experiment. Then let it run.

## 8. Cross-cutting risks

**R1 — API creep under the banner of DX.** The census is the counterweight:
clusters trend flat or down per phase; "+1 near-duplicate concept" fails T1
regardless of how nice the name is. The programme's explicit goal is a
*smaller* cognitive surface.

**R2 — PPX drift.** Every expansion snapshot is reviewed like hand-written
code (T4); any feature whose expansion needs a paragraph of explanation is
rejected at review.

**R3 — Breaking-change fatigue.** Reorganization is batched into one
changelog entry; after that, stability. If later evidence contradicts a
rename, evidence wins over sunk cost — record and revert, no sentiment.

**R4 — Vibe-check theater, autonomous edition.** Failure modes: predictions
written after sessions, reviewer sessions "primed" by shared context,
thresholds negotiated post-hoc, zero kills. Countermeasures are §4.5: sealed
predictions, fresh-context review, labelled `[agent-sim]` evidence, mandatory
kill justification in phase syntheses, `spot-check` flags for decisions
resting on simulated personas.

**R5 — Backend divergence.** T10 forces the jsoo paragraph before work
starts; a primitive with two meanings is killed, not shipped.

**R6 — Evidence rotting.** Every outcome lands in the journal under `V-DX-*`;
durable decisions promote into `docs/` (ADR for promotes; §9 for kills).
Phase syntheses cite entries or they are opinions.

**R7 — Worktree sprawl and protocol fatigue.** Long unattended runs decay:
skipped reviews, rubber-stamped ratings. Countermeasures: §4.2's loop is
checklisted per experiment; phase synthesis includes a protocol-compliance
self-audit (were predictions sealed? was the reviewer context fresh?); the
human can audit the journal at any wave boundary — it is written for that.

## 9. Parking lot (decided, with reasons)

- **`and@` for parallel CPS resource acquisition — killed by DX-E6.** The
  `with_scope` + `acquire_release` + `map_par` composition covers the case
  with zero new syntax; `and@` would need continuation rendezvous machinery.
- **Type-level effect stacks / `raise` / `subsume` / tactics / `Labelled` /
  `Tagged` — rejected.** They solve lifting pain that exists only in a
  type-level stack; Eta is stackless and passes two ordinary values instead
  (polysemy/fused-effects serve here as external evidence *for* the stackless
  choice). Recorded; do not relitigate without new evidence.
- **`NonDet` / `Choose` / `Cut` / `Cull` — rejected.** Logic programming as an
  effect; wrong library, brutal cancellation interplay.
- **Direct-style model on raw OCaml 5 handlers — rejected.** Loses the typed
  error channel (handlers are dynamically dispatched), the reified blueprint
  (`audit`/`describe` die), and cheap jsoo (CPS effects cost). The monad
  stays; direct style is the `let*` skin Eta already has.
- **Public GADT for the blueprint — rejected.** Freezes representation
  forever; `audit`/`describe` (E12) deliver ~90% of the value with zero
  freeze.
- **Zero-cost claims — rejected as marketing.** polysemy's README confession
  (specialization fails in multi-module programs) is the cautionary tale:
  Eta's benches compare against hand-written Eio and publish honest numbers.
- **`Effect.logf` (format4 logging) — deferred.** Nice ecosystem idiom;
  revisit after E20 (interception composes oddly with deferred formatting).
- **`Mtime` interop (`Duration` ↔ `Mtime.Span`) — deferred.** Small optional
  package candidate (`eta_mtime`), not core.
- **`all_settled` name — kept.** Cross-ecosystem name (JS `Promise.allSettled`)
  that people already read correctly.
- **`Mutable_ref` name — kept.** "Named Atomic" is honest; `Atomic` alone
  would oversell.
- **Slimming `Schedule.t` to two parameters — selected through DX-E24b candidate
  D (deletion proposal).** The initial A/B/C comparison correctly found that
  policy ownership is required *if structural taps remain*: top-level driver
  observers cannot see branch/phase-local handoff events, and structural
  observers restore policy-owned placement. Follow-up review added the omitted
  deletion baseline. With zero production/example tap producers and an adequate
  ordinary recipe for common attempt logging, D now proposes deleting taps, the
  hook channel, and all three interpreters. Exact structural observation is the
  explicit capability loss. Evidence: `V-DX-E24B-006`/`007`,
  `.scratch/research/dx/e24b/report.md`, and
  `.scratch/research/dx/e24b/review/DELETION_PROPOSAL.md`.

## Appendix A — Rubrics

### A.1 Call-site rubric

Rate 1–5 on the anchored scale (§3.2), then answer without docs:
(1) success/failure channels? (2) siblings/children fate on failure?
(3) where is the resource released? (4) guess-the-semantics, scored
right/wrong before rating. Record operators on hottest line, nesting depth,
distinct concepts visible, screenshot rating.

### A.2 Error-message rubric

(1) What happened, in domain terms? (2) Where — construct and location?
(3) What next — canonical fix or doc section? (4) Could a newcomer confuse
typed failure with defect/interruption from this text? Below bar on 1–3 →
rewrite or translation entry; fail on 4 → naming problem routed to the
owning experiment.

### A.3 Doc-page rubric

Task-first (first example solves a walkthrough task within 15 lines); one
recommended way above the fold; every "never/always/cannot" claim backed by
an executable assertion or test link (T5).

## Appendix B — Session scripts (autonomous)

### B.1 Persona session (30 minutes, reviewer context)

1. (5 min) Read only the README quick start.
2. (15 min) Tasks W1, W3, W4 from §3.4, docs only, no implementation.
3. (10 min) Teach-back: channel differences (`bind_error` / `fold` /
   `to_result` / `ignore_errors`); `with_resource` vs `acquire_release` +
   `with_scope`; `and*` semantics on failure.

Log: time-to-first-correct-program; doc lookups (count + pages);
misconceptions (verbatim); teach-back accuracy. Compare against sealed
predictions.

### B.2 Task cards (excerpt)

**W1.** "Read user 42 via `Db.find` returning `(user, [ \`Not_found ]) result`.
On `Not_found`, respond with a default. A crash in `Db.find` must surface as
a defect with a span name, never as a typed failure." *Pass:* correct channel
split; one recovery combinator; can say why exceptions ≠ `Not_found`.

**W6.** "Prove: retry slept 10, 20, 40 ms; the flush finalizer ran despite
interruption; no fiber is still running." *Pass:* all three in one run, no
wall-clock sleep; failure output diagnoses a deliberately broken variant.

## Appendix C — Experiment one-pager template

```markdown
#### DX-E## — Title
Phase · Effort S|M|L · Risk low|med|high
**Problem.** (one paragraph, user-shaped)
**Proposal.** (signatures; expansion if PPX)
**Semantics & edges.** (channels, cancellation, finalizers, jsoo paragraph)
**Taste check.** (principles touched, expected direction)
**Verification.** mechanical: … · review: protocol + sealed prediction + bar
**Gates.** promote if … · hold if … · kill if …
**Alternatives.** (with rejection reasons)
**Log.** V-DX-E##-001 predictions · -002 results · census/footgun deltas
```

## Appendix D — Census & footgun formats

**Census** (per experiment, per cluster): count, delta, one-line
justification per addition. Clusters: construct / handle / iterate /
lifecycle / concurrency / background / observability / logging / metrics /
syntax operators / PPX forms.

**Footgun budget:** numbered list; each entry = trap, invited bug, mitigation
(doc/type/name), owning experiment or "accepted". Releases publish the
number; direction of travel: down.

## Appendix E — Journal mechanics

- Location: `.scratch/research/journal.md`, main checkout, tracked.
- Entry IDs: `V-DX-E<NN>-<seq>` per experiment; `V-DX-STOP` for halts;
  `V-DX-PHASE-<letter>` for phase syntheses.
- Every experiment produces at least two entries: sealed predictions (before
  code) and results+decision (after gates).
- Phase synthesis contents: evidence summary with `V-DX-*` citations; wrong
  predictions and their lessons; plan adjustments; dashboard refresh; the
  spot-check list; protocol-compliance self-audit.
- The journal is the deliverable of the whole programme: a year from now it
  must answer "why is the API shaped like this?" without any living memory.

## References

- Repo: `README.md`, `docs/api-dx.md`, `docs/zio-boundaries.md`,
  `docs/services.md`, `docs/adrs/0001-…`, `AGENTS.md` (H-W4 wrap rule),
  `.scratch/research/journal.md` (V-* convention).
- fused-effects — <https://github.com/fused-effects/fused-effects>: algebra/
  carrier framing (pedagogy for E12), `Fresh` (E26), `Resumable` (E21),
  hedgehog law-testing culture (E22), handler-order-is-semantics lesson
  (E19 composition rules).
- polysemy — <https://github.com/polysemy-research/polysemy>: `reinterpret`/
  `local` (E19), `intercept` (E20), `runOutputMonoid` "run into data" (E11),
  friendly library-owned error UX (E5), tactics/`interpretH` complexity as
  the cautionary tale for Eta's narrow `Expert`, specialization/zero-cost
  confession (§9).
