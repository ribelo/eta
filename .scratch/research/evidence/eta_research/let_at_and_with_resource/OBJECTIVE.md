# V-Let-At — `let@` and the CPS-shape of Eta resource APIs

## Intent

Decide the public surface for scope-bound resource use in Eta:

1. Whether to ship `let@` in `Eta.Syntax`.
2. Whether to ship a CPS-shape companion to `Effect.acquire_release` (call it
   `Effect.use` / `Effect.with_resource` / `Effect.bracket` — the lab decides).
3. The convention downstream Eta consumers should follow when they author
   `with_*` functions over Eta primitives.

The verdict must be backed by runnable evidence, not by argument from
preference, prior art, or social pressure (a downstream consumer asked for it,
which is data, not a verdict).

## Background

A downstream Eta consumer building a real app reports a 4-deep CPS callback
chain composing `Pulse.Client.with_client`, `Pulse.Client.with_record_stream`,
`Keyboard.Monitor.with_monitor`, and `Ptt_loop.run`. They propose:

- adding `let@` to `Eta.Syntax` (callback inversion: `let@ x = f in body`
  desugars to `f (fun x -> body)`);
- adding a CPS-shape `Effect.with_resource ~acquire ~release : ('a -> ('b,
  'err) t) -> ('b, 'err) t` alongside the existing value-returning
  `Effect.acquire_release`;
- adopting a project-wide convention that downstream `with_*` functions take a
  single binder (records when multi-field) so `let@` always applies.

The consumer correctly notes that `let@` is *not* RAII: safety lives in the
`with_*` callee. `let@` is purely a layout tool.

Prior planner verdict on this thread leaned against shipping. That verdict
was reached on a wrong denominator: it counted CPS-shaped vs value-returning
sites *inside `lib/` and `test/`*, but Eta is a framework — its surface lives
in *consumer* code. The deepest nesting evidence (4-deep `with_*` chain in
real consumer use) was missing from that count.

That makes the question genuinely open. The lab exists to settle it on
evidence.

## Open question (operationally)

Given:

- existing `Effect.acquire_release` (returns the resource as a value);
- existing `Pool.with_resource`, `Effect.with_background`,
  `Semaphore.with_permits` (CPS callback last-arg);
- existing `Effect.scoped`, `Effect.finally` (take effects, not callbacks);
- existing `Supervisor.scoped` (rank-2 polymorphic body, **cannot** be
  flattened by `let@`);

what set of additions to `Eta.Syntax` and `Effect.*` (if any) makes
scope-bound resource code in *real consumer programs* clearer, harder to
misuse, and uniform enough that the rank-2 holdout doesn't poison the rest?

## Hypothesis space

Maintain a hypothesis ledger; do not narrow before evidence closes a branch.
Initial entries (the lab may add more):

| ID | Candidate | Why it might be correct |
|----|-----------|-------------------------|
| H-A | Status quo: `acquire_release` only; consumers compose `@@ fun x ->` | Smallest API surface; one canonical RAII primitive. |
| H-B | Add `Effect.with_resource` (CPS), no `let@` | Closes the asymmetry without adding a binding-operator that visually collides with `let*`. Users compose `@@ fun ->` chains as today. |
| H-C | Add `let@` to `Eta.Syntax`, no new function | `let@` already applies to `Pool.with_resource`, `with_background`, `with_permits`, and any downstream `with_*`. New function would be redundant. |
| H-D | Add both: `let@` + `Effect.with_resource` (the consumer's proposal) | Flat layout *and* uniform applicability over Eta-core scope/resource APIs. |
| H-E | Replace `acquire_release` with CPS-only form (`Effect.use`) | Narrows to one shape; forces resource-cannot-escape by construction. Breaking. |
| H-F | Defer to ecosystem: ship neither, document the `let ( let@ ) f k = f k` one-liner in cookbook | Cheapest. Consumers who want it define it locally; Eta stays opinion-free on layout. |

The lab must keep all six alive until evidence rules each one in or out, with
explicit status: Accepted / Dominated / Rejected / Deferred / Out of scope.

Do not collapse H-D into H-C+H-B; the proposal is to ship *together*, and the
combined ergonomics may exceed the sum.

## Probes (hardest-first)

P0 — Prior art (cheap, orientation only).
  - Effect-TS: how do `acquireRelease` and `acquireUseRelease` coexist?
    What does the documentation say about which to reach for?
  - Containers `CCFun.let@`, Eio examples, Dream, Httpaf, ZIO `acquireReleaseWith` /
    `scoped`, Cats Effect `Resource`. Map each to one of H-A..H-F.
  - Output: `prior_art.md` with patterns adopted/rejected and citations.
  - This is *orientation*, not verdict. Do not let prior art decide before
    real-code probes run.

P1 — Real-code refactor (HARD; the load-bearing probe).
  - Pick the deepest-nested CPS chain in:
    - `lib/http/h2/multiplexer.ml`,
    - `lib/http/h1/h1_client.ml`,
    - any test under `test/eta/test_eta_pool.ml` or
      `test/eta/test_eta_supervisor.ml`,
    - the consumer example in this objective (`Pulse.Client.with_client +
      with_record_stream + Keyboard.Monitor.with_monitor + Ptt_loop.run`),
      reproduced as a synthetic fixture under
      `.scratch/eta_research/let_at_and_with_resource/p1_consumer_fixture/`
      with stub `with_*` functions of the right shape.
  - Rewrite each *all six ways*: H-A, H-B, H-C, H-D, H-E, H-F.
  - Capture for each: indentation depth, total non-blank lines, where the
    resource binder appears in the visual flow, whether the cleanup ordering
    is obvious to a reader who hasn't seen the file before.
  - Disproof signature for H-D: it produces no measurable flatness or clarity
    win over H-C alone, *or* the synthetic consumer fixture cannot be built
    without dragging in mode/portability features that don't survive the soundness
    probe.
  - Disproof signature for H-A: every rewritten variant requires more
    indentation than the consumer's lived experience tolerates and the only
    way out is `@@ fun` ladders that the same consumer already rejects.

P2 — Misuse fixtures (HARD; the confusion-tax probe).
  - Construct three negative fixtures:
    1. `let@ x = some_effect in body` where `some_effect : ('a, 'err) t` (not a
       CPS callback). Expected: clear type error.
    2. `let* x = with_thing args in body` where `with_thing args` is a CPS
       function awaiting a callback. Expected: clear type error or, if it
       happens to type-check via inference, a documented gotcha.
    3. A function whose body mixes `let@` and `let*` in a way that makes
       cleanup ordering visually ambiguous. Capture the actual error message
       OCaml/OxCaml emits when the user gets it wrong.
  - Output: `p2_misuse/results.md` with each fixture's error verbatim. The
    quality of these messages is direct evidence on the confusion tax of H-C
    and H-D.
  - Disproof signature for H-C/H-D: the error messages are so unhelpful that
    a non-expert cannot recover. Reopens H-B / H-F.

P3 — OxCaml soundness (HARD; the load-bearing safety probe).
  - Confirm `let@` over a CPS function carrying a `local`/`unique`/portable
    resource still rejects escape, double-use, and cross-domain leakage.
  - Confirm `Effect.with_resource ~acquire ~release` (whatever the lab
    chooses to name it) preserves the same soundness gates that
    `Effect.acquire_release` currently holds.
  - At least three compile-fail fixtures in `p3_soundness/` mirroring the
    style of `lib/eta/test/soundness/`.
  - Disproof signature: `let@` *or* the new CPS function silently relaxes
    any of the existing soundness gates.

P4 — Naming bikeshed with evidence.
  - Bikeshed is unavoidable here; structure it.
  - Candidates: `Effect.with_resource`, `Effect.use`, `Effect.bracket`,
    `Effect.acquire_use_release`. Plus the do-nothing case (only
    `Pool.with_resource` exists; users write `Pool.with_resource pool @@
    fun c -> ...`).
  - Build a 1-page `p4_naming/coverage.md`: each name × each call site
    rewritten with that name. Mark visual collision with `Pool.with_resource`,
    grep ambiguity, IDE-go-to-def conflicts, alignment with prior art (P0).
  - Disproof signature: every name has at least one disqualifying problem.
    Forces a smaller surface (probably H-B with conservative naming).

P5 — Multi-binder callback shape (the `with_record_stream` question).
  - The consumer notes their `with_record_stream` callback receives `(info,
    recv)`. Their proposal: pack into a record so `let@ stream = ...` works.
  - Probe both shapes (multi-arg callback; record-packed) on at least three
    realistic consumer surfaces, including one drawn from existing
    Eta-internal code where multi-binder is currently natural (e.g.,
    `Pool.with_resource` returning a single connection — easy — vs a
    hypothetical `with_request` returning request + response writer — hard).
  - Output: `p5_multibinder/results.md` recommending a convention and noting
    every place in `lib/` where the convention would force an API change.
  - Disproof signature for H-D: forcing single-binder via records introduces
    record-allocation on every `with_*` call, observable in microbench, OR
    the convention requires cascading API changes inside Eta core that exceed
    the value of the flatness gain.

P6 — Rank-2 inconsistency tax.
  - `Supervisor.scoped` is rank-2 and `let@` will not bind under it. Quantify
    how often a real consumer function mixes scope-bound resources (where
    `let@` applies) with supervisor scoping (where it doesn't) in the same
    body.
  - If 0 such mixed functions exist in `lib/` + `test/` + the synthetic
    consumer fixture, the tax is theoretical and H-D survives.
  - If the mix is common, the on-page reading flow alternates between
    `let@ x = with_thing in` and `Supervisor.scoped (fun ~spawn -> ...)`, and
    the inconsistency cost goes on the cross-tab.
  - Output: `p6_rank2_tax/results.md`.

P7 — Prior-art alignment cross-check (cheap, last).
  - After P1–P6 produce candidate verdicts, *re-read* P0 with the verdicts in
    hand. Do Effect-TS / ZIO / Cats Effect notes the same kind of in-house
    decision the lab is about to make? If our verdict diverges from the
    nearest-shaped prior art, *write down why* — divergence is fine but it
    has to be explained by a project-specific constraint, not aesthetic
    preference.

## Decision diary shape (mandatory)

After probes close, produce `results.md` with a numbered verdict diary in the
shape established by V-Pool, V-Channel, V-Resource. Each verdict cites the
probe that supplies its evidence. Examples (do not copy verdicts; produce
your own):

> V-Let-At-1 — Decision: ship `Effect.use` (or chosen name). Evidence: P1
> rewrites show ≥N lines and ≥M indent levels saved on the consumer fixture
> compared to H-A. Counterevidence: P5 shows record-packing forces … .
> Confidence: Medium. Would change if … .

Mandatory verdicts the diary must reach:

- Whether to ship `let@` in `Eta.Syntax`. Yes / No / deferred to cookbook
  (H-F).
- Whether to ship the CPS-shape companion. Yes / No, plus the chosen name.
- Whether to mandate single-binder (record-pack) convention for downstream
  `with_*`.
- Whether and how to document the `Supervisor.scoped` rank-2 holdout so
  consumers don't trip on the inconsistency.

## Cross-tab (mandatory, in `results.md`)

Rows = decision criteria, columns = H-A through H-F. Required rows:

- Average indentation depth on P1 consumer fixture.
- Lines on the same.
- Misuse-error clarity (P2): bad / acceptable / good, with the verbatim
  error text quoted in a footnote.
- Soundness preserved (P3): yes / no.
- Naming clarity (P4): scored against `Pool.with_resource` collision, grep
  ambiguity.
- Multi-binder API impact (P5): cascading API changes needed inside `lib/`.
- Rank-2 inconsistency (P6): low / medium / high.
- Prior-art alignment (P7): aligned / divergent-with-justification /
  divergent-no-justification.
- Public-API surface delta (count of new exported symbols).

## Stop conditions

- **Stop at P1 if all six rewrites collapse to the same indentation/line
  count** (i.e., the consumer fixture isn't deep enough to discriminate).
  Pick a deeper fixture or accept that the discrimination is below noise and
  fall back to H-F.
- **Stop at P2 if H-C/H-D produce mode-soundness regressions or
  unrecoverable error messages.** Rule them out and continue with H-A/H-B/
  H-F.
- **Stop at P3 if any candidate breaks an existing soundness gate.** That
  candidate is rejected outright; do not continue probes for it.
- **Pause and escalate if P5 reveals that the multi-binder convention forces
  >5 cascading API changes in `lib/`.** That changes the cost calculus and
  the planner needs to weigh it.

## Acceptance criteria (deliverables)

1. `.scratch/eta_research/let_at_and_with_resource/` exists with:
   - `README.md` — lab index, status of each hypothesis.
   - `prior_art.md` — P0 output.
   - `p1_consumer_fixture/` — synthetic 4-deep `with_*` chain compilable
     against stubs; six rewrites; per-rewrite metrics.
   - `p2_misuse/` — three negative fixtures + verbatim error transcripts.
   - `p3_soundness/` — at least three compile-fail fixtures; pass output
     captured.
   - `p4_naming/coverage.md` — name × call-site matrix.
   - `p5_multibinder/results.md` — convention recommendation.
   - `p6_rank2_tax/results.md` — inconsistency frequency in real code.
   - `results.md` — verdict diary, cross-tab, public-surface
     recommendation, falsifier list (what would re-open the verdict).
   - `adr.md` — succinct ADR-0NNN draft for whichever surface the lab
     recommends, ready for promotion to `lib/eta/CHANGES` or equivalent.
2. Every probe is reproducible by `dune build` (or `nix develop -c dune
   build`) from the current worktree, with run logs captured.
3. The hypothesis ledger in `README.md` ends with explicit
   Accepted/Rejected/Dominated/Deferred status for **all six** initial
   hypotheses. Untested candidates must be marked *Deferred*, not silently
   dropped.
4. The verdict diary records at minimum the four mandatory verdicts above.
5. If the verdict involves shipping new code under `lib/eta/`, the ADR
   identifies *which file*, *what export*, and *what test*. The lab does
   **not** ship the implementation — that is the implementer's job after
   the planner approves the ADR.
6. The `results.md` includes a section "What evidence would change this
   verdict" listing concrete reopener triggers for each Accepted decision.

## Constraints & scope

- **No edits under `lib/` from this worktree.** The lab is research-only;
  proposed code goes in `.scratch/.../adr.md` as signatures and prose, not as
  shipped files.
- **No new Eta primitives are assumed.** The probes test layout/syntax and
  one possible new function (`Effect.use` / `Effect.with_resource`) over
  existing primitives. Any deeper change (new runtime hook, new mode
  annotation) is out of scope and must be filed as a separate research
  task.
- **The rank-2 `Supervisor.scoped` body stays rank-2.** Reshaping it to fit
  `let@` is out of scope.
- **Build via `nix develop` or `OPAMROOT=$PWD/.opam-oxcaml; eval "$(opam env --switch 5.2.0+ox --set-switch)"`.**
- **Hardest-first stop-at-falsifier ordering** is mandatory. Do not run P4
  (naming) or P7 (prior-art alignment) before P1–P3 produce verdicts.
- **No verdict without captured run logs.** Every "PASS" / "FAIL" must point
  to a file the planner can re-run.

## Out of scope

- Reshaping any existing CPS-shape function (`Pool.with_resource`,
  `Effect.with_background`, `Semaphore.with_permits`). They stay as they
  are.
- Reshaping `Effect.acquire_release` (value-returning). It coexists with
  any new CPS-shape companion.
- Adding `let@` to any module other than `Eta.Syntax`.
- Touching `Supervisor.scoped` rank-2 type machinery.
- The cookbook / documentation pages themselves. The lab decides *what to
  document*; the words land in a follow-up task.

## What the experimenter should not do

- Optimize for an unstated metric (line count alone, file count alone, fewest
  exported symbols alone). The cross-tab must be honest about all rows.
- Reject `let@` because OCaml convention is conservative, *or* accept it
  because Containers / Eio examples use it. Both are prior-art arguments and
  belong in P0/P7, not the verdict.
- Collapse H-D into "obviously the union of H-B and H-C" without running
  P1 to confirm the combined ergonomics actually exceed the parts.
- Produce a verdict before P1, P2, P3 close.
- Skip P5; the multi-binder convention is the part most likely to bite
  downstream API design and silent-deferral here would be malpractice.
- Treat the downstream consumer's example as proof. It is *evidence of
  shape*, not proof of correctness.

## References

- Consumer proposal: chat transcript inserted in this task description
  (`Pulse.Client.with_client + with_record_stream + Keyboard.Monitor +
  Ptt_loop`).
- Existing Eta surface: `lib/eta/effect.mli` (acquire_release, scoped,
  finally, with_background), `lib/eta/pool.mli` (with_resource),
  `lib/eta/semaphore.mli` (with_permits), `lib/eta/syntax.{ml,mli}`,
  `lib/eta/supervisor.mli` (rank-2 scoped).
- Existing soundness fixtures style: `lib/eta/test/soundness/`.
- Prior labs to mirror in shape: `.scratch/eta_research/pool_survival/`,
  `.scratch/eta_research/channel_choice/`, `.scratch/eta_research/timeout_choice/`.
- Prior art to read in P0: Effect-TS `Effect.acquireRelease` /
  `acquireUseRelease`, ZIO `ZIO.acquireReleaseWith` / `Scope` / `scoped`,
  Cats Effect `Resource`, Containers `CCFun.let@`, Eio `Switch.run` and
  `Net.with_tcp_connect`.
