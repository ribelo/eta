# Objective: DX-E24b — Schedule-hook ownership: policy vs. driver (decision experiment)

- Worktree: `/home/ribelo/projects/ribelo/ocaml/Eta-dx-e24b`
- Branch: `research/dx-e24b-hook-ownership` (already checked out here; do not create others)
- Phase: E (research) · Effort S–M · Risk contained (research-first; implement only what the verdict requires)
- Registered: V-DX-E24-003 (E24's slimming hold + oracle consultation)
- Evidence IDs: `V-DX-E24B-*` (orchestrator log); your journal is the branch record

## Executor profile

An architectural decision experiment, not an implementation task. The
deliverable is a *decision with evidence*: a complete driver inventory, a
semantics matrix, a steelmanned hypothesis space, a cross-tab, and a
verdict diary — per the evidence-based-coding discipline at its purest.
Reading-heavy (runtime internals, all drivers); writing = the decision
record plus whatever the verdict demands (doc prose, test registrations,
or a migration design). "Retain hooks permanently" is a live, respectable
outcome. Strong semantics comparison; no code production beyond the
verdict's needs.

## Mission

Eta may be complicated inside; using Eta must feel beautiful. The
`Schedule.t` third type parameter is either load-bearing architecture or
the library's ugliest public type — decide which, with evidence, and close
the question Phase A opened.

## Read first (in order)

1. `AGENTS.md` — Nix-only gates, no shims, break loudly. **E22 policy:
   any law-bearing prose you add or change in an `.mli` needs a named test
   in the same change.**
2. `lib/eta/schedule.mli` — the full driver protocol: `start`, suspended
   `step = Complete | Hook of 'hook * (unit -> step)`, `step_plan`,
   `step_with_hooks`, `step`, `next`, `no_hook`.
3. The drivers: `lib/eta/effect_schedule.ml` (retry family —
   `step_with_hooks`), `lib/eta/resource.ml:62-93` (`Resource.auto` —
   hand-interprets `Hook`), `lib/stream/eta_stream.ml:271-277` +
   `eta_stream.mli` (×4 hook-schedule operations).
4. `.scratch/research/dx/e24/journal.md` + the E24 retro ledger entry —
   the hold's origin. The two consultation guardrails: inventory must
   cover the FULL public driver protocol including `step_with_hooks`
   (evaluate that seam before inventing per-driver callbacks); taps are
   not merely observers (pre-step, post-step-incl-Done, failure changes
   control flow, ordering under composition).
5. `.scratch/research/dx/e13/report.md` and `dx/e14/report.md` —
   contract-promise semantics vocabulary (context for any driver redesign).

## Method

Evidence-based-coding discipline:
`/home/ribelo/.pi/agent/skills/engineering/planning/evidence-based-coding/SKILL.md`
— this experiment IS the skill's workflow: question, proof obligations,
hypothesis space, evidence, cross-tab, verdict diary. Working artifacts in
`.scratch/research/dx/e24b/` **on this branch** (commit them):
`journal.md`, `report.md`, `redteam/`, `review/`.

## The question

Are effectful hooks owned by the schedule **policy** (today: the third
type parameter + `tap_input`/`tap_output`, carried through every
hook-accepting signature) or by every **driver** (per-driver observer
callbacks)? Decide with evidence and close it — including the option that
the question itself is miscut.

**Candidates (steelman each):**
- **A. Retain policy-owned hooks.** Kill the slimming permanently. The
  third parameter is the price of one mechanism serving `retry`,
  `Resource.auto`, `Eta_stream`, and public `step_plan` drivers; the
  suspended-step design already splits ownership (policy = hook VALUES,
  driver = hook INTERPRETATION). Refine: ownership prose in the mli +
  law coverage.
- **B. Driver-owned observers.** Slim `Schedule.t` to 2 params, delete
  taps, and give each driver its own observer contract
  (`Effect.retry`'s `?on_retry`, `Resource.auto`'s `?on_step`,
  `Eta_stream`'s ×4, public-driver guidance). Must cover the full
  semantics matrix or it's an incomplete second hook system.
- **C. Seam-centered redesign.** Rebuild around the suspended-step /
  `step_with_hooks` seam — e.g. hooks stay in the type but the
  ergonomics change (hide the third parameter from common signatures;
  `no_hook` for the tap-free majority; or a single public interpreter
  combinator).

## Required evidence (the matrix is the deliverable)

1. **Inventory** (verify, don't assume): every hook consumer, every
   driving style, every public protocol entry point. Known: retry family
   (`step_with_hooks`), `Resource.auto` + `Eta_stream` (hand-interpreted
   `Hook`), taps constructed only in tests (16 lines, 3 files).
2. **Semantics matrix**: rows = pre-step (`tap_input` before state
   advancement), post-step (`tap_output` incl. terminal `Done`), hook
   failure (fails the driving effect; no advancement on `tap_input`
   failure), ordering under schedule composition (`and_then` etc.),
   suspended interpretation (`Hook` resumption), no-hook ergonomics;
   columns = each candidate; cells = how the candidate expresses the row
   (or CANNOT).
3. **The disconfirming probes** (executable where behavior is claimed):
   for B, demonstrate one semantics row it cannot express or one
   duplication it introduces; for A, steelman the strongest B (the
   minimal sufficient observer set) and show the cost; for C, show what
   breaks or improves at the 6+ threaded signatures.
4. **E22-policy reckoning**: hook semantics are law-bearing prose —
   register existing test coverage (the 16 tap lines) or add what's
   missing, per the census rules.

## Deliverable shapes (per verdict)

- **A lands**: mli ownership prose (the split stated in one or two
  sentences — replacing the "hardest paragraph" is most of what the
  original slimming wanted); parking-lot entry for the slimming with
  this evidence; law registrations; gates green. No code change beyond
  prose/tests.
- **B lands**: the minimal observer design per driver + semantics
  parity proof + migration plan — as a follow-up experiment proposal,
  not implemented here (scope: decision only).
- **C lands**: the redesign + signature migration plan — as a follow-up
  experiment proposal, not implemented here.

## Protocol (predictions commit FIRST and separately)

1. **Seal your predictions** in `.scratch/research/dx/e24b/journal.md`:
   expected matrix contents, expected verdict, what evidence would flip
   you. Commit before any work (`docs(dx-e24b): seal predictions`).
2. **Inventory + matrix + probes** (the evidence, in the journal).
3. **Verdict diary** (V-X entries: ACCEPT/REJECT/DEFERRED with evidence,
   counterevidence, remaining uncertainty, confidence, "would change if").
4. **Gates** (whatever the verdict): native trio; mainline
   `@install`/`test/laws` if prose or tests changed; `docs` builds.
5. **Review packet** in `review/`: the decision record itself
   (inventory, matrix, cross-tab, verdict) + `QUESTIONS.md` for the
   reviewer ("is the matrix complete? does the verdict follow? what's
   the strongest objection the record doesn't answer?").
6. **Report** in `report.md`: verdict, matrix, census/footgun deltas,
   prediction scoring, follow-ups registered (if B or C: the follow-up
   experiment one-pager).

## Done means

Your final message ends with exactly one of:

- `E24B READY FOR REVIEW`
- `E24B BLOCKED: <reason>`
- `E24B STOP: <§4.6 stop condition>`

## Scope fence

- Never read or touch: `.scratch/research/dx-journal.md`, `docs/research/`,
  `.scratch/research/dx-prd-0001.md` beyond what you need for E24/E24b
  context (§E24, the parking lot), `.scratch/research/orchestrator-state.md`.
- Never push, never commit to master, never create branches, never edit
  `objective.md` (leave it uncommitted).
- Decision-first: no implementation beyond what the verdict requires
  (prose, test registrations). A B or C verdict produces a PROPOSAL, not
  code.
- Stay in E24b's surface. Adjacent discoveries → journal follow-ups.
- Everything under `.scratch/research/dx/e24b/` must be committed;
  `objective.md` stays uncommitted.
