# DX-E37 report — one canonical parallel-acquire combinator

## Result

**E37 READY FOR REVIEW.**

`Effect.acquire_all_par` is the single homogeneous parallel-acquisition API. It
owns the staging, rollback, cancellation, transfer, ordering, and finalizer
diagnostic protocol without exposing `Effect.Expert`. No arity or heterogeneous
variant was added.

## Public contract

```ocaml
val acquire_all_par :
  ?max_concurrent:int ->
  acquire:('c -> ('a, 'err) t) ->
  release:('a -> (unit, 'r) t) ->
  'c list -> ('a list, 'err) t
```

The `effect.mli` contract occupies seven documentation lines. It states input
ordering, `map_par` admission/default/rejection parity, reverse-success rollback,
late-completion cleanup without transfer, ownership transfer across all scope
exits, and existing finalizer-cause reporting. Rows R146-R153 in
`.scratch/research/dx/e22/review/LAWS.md` register every new claim against named
executable evidence.

## Implementation

The implementation is a private staging scope over the existing bounded worker
engine:

1. Each worker checks cancellation before starting queued acquisition work.
2. On acquire success, its release is prepended to the staging finalizer stack.
3. Only after rollback is armed does the worker yield at the cancellation fence.
4. Failure or interruption leaves staging armed; ordinary scope finalization
   awaits all workers and rolls back in reverse successful-acquisition order.
5. Full success performs one final cancellation check, constructs
   `staged @ owner`, then moves the complete stack into the owner without a
   suspending operation between mutations.

This reuses `collect_workers`, `run_scope_body`, and
`Runtime_core.with_finalizers`. It adds no runtime-contract operation, public
module/type, compatibility path, fallback, or `Expert` surface.

## Semantics evidence

| Edge | Named executable evidence | Result |
| --- | --- | --- |
| Concurrent/default/explicit admission and nonpositive rejection | `acquire_all_par admission and concurrency` forces ten blocked inputs to reach exactly the default eight, then seven inputs to reach exactly an explicit three, and rejects zero at construction | proven |
| Acquire failure and in-flight cancellation | `acquire_all_par failure reverse cleanup` forces `a`, then `b`, then failure while a fourth child is in-flight; exit stays the acquisition failure, the fourth observes interruption, and releases are exactly `b,a` | proven |
| Late completion after cancellation | `acquire_all_par cancellation late completion` allows an uninterruptible acquire to return only after sibling failure; rollback is `late,a` before recovery continues, success continuation is skipped, and owner exit adds no duplicate | proven |
| Empty fiber census | `acquire_all_par late completion census` repeats the late-completion attack through `Eta_test.Run` and requires an available empty structured-fiber census | proven |
| Success ownership on every exit | `acquire_all_par scope exit ownership` observes no release during the body and exact `second,first` release after success, typed failure, defect, and interruption | proven |
| Release diagnostics | `acquire_all_par release diagnostics` makes both releases fail; all run in `2,1` order, success produces a sequential `Cause.Finalizer`, and body failure remains primary with the full sequential finalizer diagnostic suppressed | proven |
| Input order | `acquire_all_par input order` forces completion `3,1,2,0`, returns `0,1,2,3`, and releases `0,2,1,3` | proven |

Observation boundary for the six core tests is the complete Eio runtime exit and
release trail. The late-cancellation companion additionally observes Eta_test's
root-exit fiber census. No test relies on wall-clock timing.

## Docs migration

`docs/api-dx.md` now uses one ordinary homogeneous recipe:

```ocaml
Effect.with_scope
  (Effect.acquire_all_par ~acquire:Db.connect ~release:Db.close configs
  |> Effect.bind body)
```

The former recipe block contained six `Effect.Expert` calls; the ordinary block
contains zero. `Effect.Expert` is mentioned only in the demoted heterogeneous,
library-integration note. `acquire_release` and `with_scope` documentation now
point homogeneous parallel acquisition to `acquire_all_par`.

## Census and footgun score

Detailed commands and counts are in `.scratch/research/dx/e37/census.md`.

| Prediction | Actual | Score |
| --- | --- | --- |
| Public values `+1` | top-level `Effect` vals 129 -> 130 | hit |
| Public modules/types `+0` | no public module/type added | hit |
| Homogeneous parallel acquisition no longer requires application `Expert` | ordinary recipe Expert calls 6 -> 0 | hit |
| Footgun `-1`, new footguns `+0` | ownership bridge moved inside one canonical strategy-named combinator; no fallback/default beyond inherited bound | hit |
| Contract fits about ten lines | seven documentation lines | hit |
| Review outcome READY if semantic and dual-runtime gates pass | all required gates pass | hit |

The sealed cancellation prediction was behaviorally correct but named the late
resource's cleanup owner as its child scope. The implementation uses a dedicated
staging scope instead. Score: semantic hit, internal-mechanism miss. The broader
implementation prediction (private frame/scope bridge, cancellation-safe commit,
no new runtime operation) hit.

## Red-team outcome

Artifacts are under `.scratch/research/dx/e37/redteam/`:

- `a-partial-race.md` — completed resources plus a failing and an in-flight
  acquisition: reverse rollback and interruption pass.
- `b-late-cancellation.md` — finite uninterruptible late completion: no owner
  transfer, no duplicate release, and empty fiber census pass.
- `c-release-failure.md` — two failing releases: every release runs and the
  primary cause remains primary.

The strongest disconfirming observation was real: a staging prototype using a
non-scheduling cancellation check left one structured fiber visible at the
Eta_test root-exit census. Arming rollback and then yielding at the transfer
fence closed that observation; both focused suites then passed. One separate
test expectation initially assumed a previously completed resource should stay
owner-held after a sibling acquire failure; the objective requires transactional
rollback, so the expectation was corrected to prompt `late,a` cleanup. Each
failure class was fixed within one forward attempt.

## Verification

All assignment gates are green on the final code/test tree:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c eta-oxcaml-test-shipped
nix develop .#mainline -c dune build --build-dir=_build-mainline @install
nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/js_jsoo --force
```

Focused development evidence is also green:

```sh
nix develop -c dune runtest test/core_eio test/test --force
```

The focused run executed 626 core Eio tests and 41 eta_test tests.

## Hypothesis status

| Candidate | Status | Evidence |
| --- | --- | --- |
| Private staging scope plus one batch commit | accepted | all semantic, census, native, shipped, mainline, and JS gates pass |
| Direct per-child registration into the owner (former Expert recipe) | rejected | failure recovered inside the owner would retain partial resources; rollback test requires cleanup before recovery |
| Custom atomic owner-finalizer aggregator | dominated | it passed focused evidence, but existing staging/finalizer machinery expresses the same protocol with materially less code and authoritative cause handling |
| New heterogeneous or arity-specific public API | out of scope | excluded by the E6 and objective fences, not tested or rejected on technical feasibility |

## Decision diary

- **V-DX-E37-1 — ship one homogeneous ownership combinator.**
  Status: ACCEPT.
  Evidence: all six pinned semantics plus empty-census red team and all gates.
  Counterevidence: a plain public-combinator recipe cannot transfer ownership;
  direct owner registration fails transactional rollback.
  Confidence: high.

- **V-DX-E37-2 — use staged finalizers and one batch transfer.**
  Status: ACCEPT.
  Evidence: exact reverse completion ordering, late cancellation, every exit
  kind, and authoritative finalizer diagnostics.
  Remaining risk: a finite uninterruptible acquisition necessarily delays the
  structured join and therefore rollback return; detaching it would violate the
  no-leak and census requirements.
  Confidence: high.

- **V-DX-E37-3 — keep heterogeneous acquisition advanced.**
  Status: ACCEPT AS SCOPE BOUNDARY.
  Evidence: the canonical user case is homogeneous and the E6 review killed
  cardinality wrappers. No heterogeneous public candidate was investigated.
  Confidence: high that this change should not widen the surface.

## Deviations

The objective's historical ref `research/dx-e6-scoped-with-2-3` was unavailable
locally. The available branch `research/dx-e6-scoped-with-helpers` contained the
requested E6 report and its final kill outcome, so that report supplied the
required E6 constraint. No mission or implementation scope was widened.

## Recommendation

Promote to adversarial review. The implementation centralizes a protocol that
ordinary public combinators cannot express, carries an execution-strategy name
rather than E6-style cardinality, and matches the sealed surface/footgun
prediction. The code, docs, executable law registry, red-team record, and report
agree.
