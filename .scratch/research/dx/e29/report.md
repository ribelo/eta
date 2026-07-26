# DX-E29 Report — `par3` / `par4` concurrent product ergonomics

## Outcome

Built candidate A: `Effect.par3` and `Effect.par4`, flat-tuple concurrent
products with semantics inherited from `par` over the existing
`par_run_forks` machinery. All pre-registered technical gates pass. The
frequency evidence is reported straight below; the promote-vs-kill
decision belongs to the PR-style review gate.

Commits on `research/dx-e29-par-ergonomics`:

| Commit | Content |
|---|---|
| `5c004eea` | `docs(dx-e29): seal predictions` — census.md + journal.md (sealed before code) |
| `ec75fad0` | `feat(dx-e29): par3 / par4 flat-tuple concurrent products` — mli, implementation, suite tests, qcheck laws, registry rows |
| `9ee7063d` | `test(dx-e29): red-team probes for nested-tuple mismatch class` |

## Gates

Pure-addition change (two new vals, their tests, their registry rows; no
change to `par`, `all`, `map_par`, `Syntax`, or any runtime machinery).
Stated as such; gates run anyway, all green on the final tree:

```sh
nix develop -c dune build @install        # green
nix develop -c dune runtest --force       # green
nix develop -c eta-oxcaml-test-shipped    # green
```

Fix attempts used: one compile round (heterogeneous children cannot be
aggregated through a homogeneous list literal; names/footprints are folded
per child instead) and one test-expectation round (audit `uses_clock`
expectation for an `Effect.log` child; exact-`Fail` expectation corrected
to the `par`-family `Concurrent` cancellation shape). Both ≤ 3 per class.

## Design question 1 — frequency (reported straight)

Primary artifact: `census.md`. Orchestrator's count was "nested-`par`
sites: 2, one test file". Actual: **3 sites, 2 test files** — the
orchestrator missed the right-nested second-argument form at
`test/laws/law_properties.ml:463`.

| Site | Shape | Consumer-shaped? |
|---|---|---|
| `test/core_common/promise_shared.ml:123` | left-nested, destructured `(((), live), won)` | no — test-harness interleaving |
| `test/core_common/promise_shared.ml:219` | left-nested, meaningful 2-vs-3 grouping | no — test-harness interleaving |
| `test/laws/law_properties.ml:463` | right-nested, results discarded | no — qcheck cleanup law |

Context: 143 compiled flat `par` call expressions at 140 sites; nesting
rate ≈ 2.1%. Zero nested sites in `lib/` product code, `examples/`,
`drivers/`, `http-testsuite/`. No pipeline nests, no partial applications,
no `Syntax` spelling, no data-flow nesting, no fan-out above 3.

**Honest answer: the pain is not demonstrated in-repo.** The case is
purely structural: E9b made `Effect.par` THE spelling for concurrent
products, so external consumers with 3+ heterogeneous concurrent fetches
are structurally forced into nested tuples or a flattening `map`. Two
framings were weighed and are both recorded: (a) T4 — sugar follows
demonstrated frequency, and in-repo frequency is ≈ 0 (the `sync_option`
reading); (b) Eta is a library for external consumers — this corpus is the
runtime authors' own usage and cannot measure consumer-side ergonomic
pain, so in-repo rarity is weak evidence against an outward-facing
spelling. The census can only settle (a)'s fact; the gate that weighs (a)
against (b) is the review.

## Design question 2 — hypothesis ledger (final statuses)

| Candidate | Status | Ground |
|---|---|---|
| **A — `par3`/`par4`** | **Built; promote candidate to review.** | Semantics inherit cleanly (below); red-team shows the treated bug class removed with no new hole; frequency reported straight. |
| **B — builder/applicative chain** | **Deferred, untested.** | Census max fan-out is 3; the cap-4 rule never bites in-repo, so there is no evidence base for B's extra machinery. Revive only if the review or downstream evidence shows the cap biting. Not rejected on proof cost — rejected on absence of the triggering condition. |
| **C — kill (status quo)** | **Alive; delegated to the pre-registered review kill gate.** | In-repo frequency ≈ 0 is real and is the strongest kill argument. Not self-executed: the objective places the kill gate in the PR review, and the E6 kill rationale (cardinality name hid execution strategy) does not transfer — `par3` hides nothing; its semantics are visibly inherited from `par`. |

## Design question 3 — semantics inheritance

Implementation: flat forks over the existing `par_run_forks`
(`lib/eta/effect_concurrent.ml`), one promise per child via a small
`promise_fork` helper mirroring `par_pair`; fail-fast, internal-cancel,
and cause aggregation are the same code path `par` uses. No new semantics.
Blueprint: `leaf_name:"Effect.par3"/"Effect.par4"`, names concatenated,
footprint unioned with `has_concurrency` — like `all`.

Executable evidence (shared suites, both runtimes):

| Obligation | Test | Result |
|---|---|---|
| Result order = argument order under reversed completion | `par3/par4 returns triple/quadruple in argument order` | proven |
| Children genuinely concurrent (rendezvous) | `par3/par4 children run concurrently` | proven |
| Fail-fast from EVERY position cancels ALL siblings | `par3 fail-fast cancels all siblings` (3 positions), `par4 ...` (4 positions) | proven |
| Cause of the observed failure is exact `Fail` when siblings are bare | same tests (`Cause.Fail "boom"`) | proven |
| Cancelled scope-holding siblings' finalizers complete before return | `par3/par4 cancelled siblings release before return` | proven |
| Cancellation cause shape parity with `par`/`all` baselines | same tests assert `Concurrent` with body failure observed (mirrors `test_par_finalizer_failure_during_sibling_cancellation` and the `all` baseline) | proven |
| Blueprint names/footprint aggregate all children | `par3/par4 audit aggregates children` (names list, `has_concurrency`, clock/log union) | proven |

Law-registry rows M119–M122 cite named qcheck properties (generated
class: values × base delay × both completion directions; winner position ×
error × delay for fail-fast; observation boundary: sealed exit + ordered
log events + empty pending-fiber census), 50/50 cases each:

- `par3/par4 preserves triple/quadruple input order across both observable completion directions`
- `par3/par4 first observed failure cancels every sibling and awaits cleanup`

**Known honest difference from literal nesting** (sealed in P2, confirmed
in test): under simultaneous multi-child failure the cause tree is flat
(`Concurrent[Fail body; Interrupt; Interrupt]`), not
`Concurrent`-of-`Concurrent` as literal `par (par a b) c` nesting would
produce. `par`'s own contract does not pin nesting depth, and the
`par`/`all` cancellation baselines assert the same flat shape, so this is
family-consistent, not a deviation.

## Census / footgun actuals vs sealed predictions

| Prediction | Sealed | Actual | Score |
|---|---|---|---|
| P1 frequency completeness | no further forms beyond 3 sites | none found through build/red-team | **hit** |
| P2 semantics inheritance | clean, zero runtime changes, cause-tree shape documented | exactly that; one compile fix and one expectation fix, both in budget | **hit** |
| P3 census delta | concurrent-product vals 4 → 6 (+2 vals, +1 concept, +0 modules); registry +4 rows | 4 → 6 (`par`,`all`,`all_settled`,`map_par` + `par3`,`par4`); M119–M122 added; header 108→112 claims, 69→73 properties | **hit** |
| P4 footgun delta | −1 / +0 | −1 (mismatch invitation removed) / +0 (red-team Q2) | **hit** |
| P5 review outcome | PROMOTE, ~55% | pending — review is the orchestrator's gate | unscored |

P3 honest overflow: inserting `par3`/`par4` shifted every `effect.mli`
line after 209 by +23, so all 155 registry span cells were rewritten
mechanically; three pre-existing drifted spans (M08, M26, M33 — pointing
one to two lines off their normative text since an earlier shift) were
repaired to exact lines. No claim rows were added or removed by the shift.

## Red-team

Artifacts: `redteam/` (4 probes + raw compiler output + VERDICT.md).

- Probes 1–2 (status quo): flat pattern on left-nested `par`, and
  left-nested pattern on right-nested `par` — both rejected with errors
  that force the user to decode tuple nesting. The bug class the sugar
  treats is real DX friction, caught statically but billed to the user.
- Probe 3 (`par3` + flat pattern): compiles. The treated form.
- Probe 4 (`par3` + nested pattern): rejected with identical strictness.
  The fence is not weakened.

Honest scope of the win (as sealed in P4): the typechecker already made
the mismatch unwritable; `par3` removes the *invitation* by making the
correct spelling coincide with the user's flat-triple mental model. No new
static guarantee; no new footgun class (arity temptation fails loudly at
the application; `par4`-vs-`all` overlap is result-shape only; failure
position and completion-order observability are inherited unchanged).

## Recommendation against the pre-registered gates

**Promote A to review.**

- Semantics inherit cleanly with tests: **met** (above).
- Frequency evidence reported straight: **met** — ≈ 0 in-repo, said so.
- PR review prefers flat tuples over the status quo: **pending** — this is
  the review's call, and it is the whole experiment.

The strongest honest promote case: the comparison is not E6's ladder
(whose nesting carried visible acquisition strategy) — nested `par`
carries none; the nesting is a pure accident of a binary API, and the
flattening `map` a consumer must write today is noise. The strongest
honest kill case: T4 + `sync_option` — demonstrated in-repo frequency is
≈ 0, and a library that ships sugar on structural arguments alone
accumulates furniture. Both are on the record; the kill gate lives with
the review.

If killed: excise `par3`/`par4`, their suite tests, the four qcheck
properties, and registry rows M119–M122 (restoring the 108/69 header
counts); keep `census.md`, `journal.md`, this report, and the red-team as
the evidence record. No rename rescue.

E29 READY FOR REVIEW

## Follow-up 1 — promote verdict and pre-merge fixes

The review returned **promote** (kill case weighed and rejected) with
three mechanical pre-merge fixes. Sealed P5 (PROMOTE, ~55%) scores as a
**hit**; all other sealed predictions scored above. Fixes applied in
`27ca04c9`:

- **M1 — stale LAWS.md census totals.** The per-module totals table now
  matches the header: effect.mli direct claims 55 → 59, its covered
  registry rows 155 → 159, total covered 108 → 112, covered registry rows
  236 → 240, unique properties 69 → 73.
- **M2 — fail-fast properties enumerate every winner position.**
  `par_n_fail_fast_property` now generates only (error, base delay) and
  deterministically executes all 3 (`par3`) / 4 (`par4`) winner positions
  per run, so a position-specific regression cannot hide behind a lucky
  seed. Property names and claim statements are unchanged; the registry
  rows M119–M122 still cite them. Verified: `dune runtest test/laws
  --force` — 73/73 pass.
- **M3 — footprint audit discriminates every child position.** Each child
  now carries a unique footprint-originating capability — `par3`:
  resources/logs/metrics; `par4`: resources/logs/metrics/background — and
  the test asserts the union, so a footprint flag dropped from any single
  position fails. Verified in the shared suite (`par3/par4 audit
  aggregates children`, both runtimes).

Gates re-run on the final tree, all green:

```sh
nix develop -c dune build @install        # green
nix develop -c dune runtest --force       # green
nix develop -c eta-oxcaml-test-shipped    # green
nix develop -c dune runtest test/laws --force  # green, 73/73
```

No design change, no new law-bearing prose, no scope-fence deviation.
Journal note: `journal-followup-1.md`; the sealed `journal.md` is
untouched.

E29 READY FOR REVIEW
