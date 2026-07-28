# DX-E40 Report — `all` admission split

## Outcome

**E40 READY FOR REVIEW after Follow-up 1.** The four review fixes are complete:
gated registration makes the admission contract true on Eio, backend-level and
generated regressions pin it, the breaking change is in the changelog, and the
fan-out footgun is registered and documented. All required gates pass.

## Implemented contract

- `Effect.all effects` forks one fiber per input and registers every child fiber
  behind a start gate before any child body starts.
- `Effect.all_bounded ~max_concurrent effects` preserves the E28 worker-pool
  engine under a required positive bound and rejects nonpositive bounds at
  construction.
- `Effect.all_settled` keeps its signature and uses the same registration gate;
  failures remain materialized child outcomes.
- `map_par` is unchanged.

`fork_after_registration` is the one shared mechanism: every wrapper's first
action awaits the start promise, the parent resolves it after the registration
loop, and a post-gate cancellation checkpoint prevents not-yet-started bodies
from running after fail-fast cancellation. `all` opts into it through
`par_run_forks`; `all_settled` uses it directly. `all_bounded` alone uses
`collect_workers`.

## Executable evidence

| Obligation | Evidence | Result |
| --- | --- | --- |
| Every `all` child registered before bodies start | `all registers one fiber per generated child before synchronous first failure`; counted Eio regression | PASS |
| `all` coordination immunity | `all admits every generated rendezvous participant without admission deadlock`; shared `all admits full coordination group` | PASS |
| Bounded coordination stall possible | `all_bounded can stall when every admitted child awaits an unadmitted participant`; shared `all_bounded stalls below the coordination group size` | PASS |
| Bound enforced | `all_bounded never exceeds max_concurrent and reaches the bound when children suffice` | PASS |
| Construction rejection | generated nonpositive property plus shared zero/negative examples | PASS |
| Input order | generated reverse-completion properties for `all` and `all_bounded`; shared delayed-order test | PASS |
| Fail-fast/cancellation/finalizers | generated properties for both engines; existing shared recovery/finalizer baselines | PASS |
| `all_settled` registration alignment | `all_settled registers every generated child before synchronous first failure`; counted Eio regression | PASS |
| Empty fiber/sleeper census | both generated barrier directions and shared pair | PASS |

Focused commands passed:

```sh
nix develop -c dune build lib/eta/eta.cmxa
nix develop -c dune runtest test/laws test/core_common --force
nix develop -c dune runtest test/core_eio --force
```

Raw focused outputs are in `dossier/deadlock-*.txt`.

## Omission census and migrations

The final lexical census contains **108 omission sites**: all 108 are
safe-to-widen and none has a load-bearing hidden bound. No omission was silently
rebounded. The 55 consumer/example/benchmark sites match the sealed detailed
predictions; the additional verification/new-law sites are individually listed
in `dossier/omission-census.md`.

All seven explicit `~max_concurrent` syntax sites were migrated through the
registered split. Bounded construction and tail-admission witnesses use
`all_bounded`; the old explicit-full-fan-out witnesses became the positive
plain-`all` side of the new barrier guarantee.

## Law registry

The census-complete `effect.mli` rows now state:

- M114/M127/M115: one fiber per input, registration before body start, and no
  child withheld by `all` admission;
- M116/M117 and M123–M125: bound, rejection, order, and fail-fast behavior for
  `all_bounded`;
- M126: registration before body start for `all_settled`;
- R127: the named bounded coordination caveat.

The direct census is 116 claims and 77 unique QCheck properties. No stale
omission-means-eight or explicit-length recipe remains. Registry diff:
`dossier/law-registry.diff`.

## Census and footgun deltas

- Public concurrency values: **+1**.
- `all` optional arguments: **-1**.
- Footguns: **-1/+1**. The hidden cap-eight stall is removed; unbounded `all`
  adds a visible fan-out risk of approximately one fiber per input.
- Omission migrations to a hidden bound: **0**.
- `all_settled_bounded`: not added; no structural need surfaced.

## Sealed prediction score

| Prediction | Actual | Score |
| --- | --- | --- |
| `all` can reuse ungated fork-all beside `all_settled`; no engine tangle | No worker-pool tangle, but ungated sequential registration was false on Eio | Miss |
| `all_bounded` preserves E28 worker pool and rejects nonpositive values at construction | Exact | Hit |
| Same barrier completes under `all` and times out at `N - 1` under `all_bounded` | Exact shared pair; generated positive uses a finite-yield equivalent and negative retains the timeout | Hit |
| Fail-fast, order, cancellation, and finalizers remain | Focused shared and generated suites pass | Hit |
| No omission has a load-bearing hidden bound | 108/108 safe-to-widen | Hit |
| Public delta `+1 val`, `all` loses optional | Exact | Hit |
| Footgun delta `-1/+0` | Actual `-1/+1`; corrected in the sealed follow-up amendment | Miss |
| Four required gates pass | All exact commands pass | Hit |

## Deviations

- The sealed journal listed every consumer/example/benchmark site and grouped
  verification witnesses. The final review census expands those groups and new
  law witnesses to 108 individual rows; classifications did not change.
- A broad discovery command accidentally returned one matching line from the
  forbidden `docs/research/` tree. No further access or modification occurred,
  and that line was not used as evidence; all decisions rely on the assigned
  sources, product tests, and tracked E40 artifacts.

## Independent review history

The initial technical review identified and closed the M123 bounded-order gap,
but missed the Eio registration defect. Follow-up 1 then reproduced the central
failure: sequential `fiber_fork` let a synchronous first-child failure stop the
registration loop at one child. This report supersedes the initial no-defect
conclusion with the counted registration evidence below.

Follow-up 1 was issued after the previously disclosed accidental scope-fence
search match and defined four precise promotion blockers. Those four blockers
are the closure criteria scored here; no forbidden path was read or modified
during the follow-up.

The final read-only PR review found no runtime or API blocker. It caught one
stale registry-total table; the table now agrees with the rows and header at 116
direct claims, 169 external rows, 285 covered rows, and 77 unique properties.

## Required gates

| Command | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline test/cache_jsoo test/js_jsoo test/signal_jsoo test/http_js` | PASS |

Focused Follow-up 1 evidence also passes:

- three Eio admission cases in `dossier/followup-admission-output.txt`;
- all 77 generated law properties, with the registration subset in
  `dossier/followup-law-output.txt`.

## Follow-up 1 closure

### Four requested fixes

1. **Admission gate:** `all` and `all_settled` share
   `fork_after_registration`. Every registered wrapper first waits on the start
   promise; the parent releases it after the loop. A cancellation checkpoint
   between the wait and body prevents not-yet-started work from running after an
   `all` failure.
2. **Synchronous-failure regression:** a counted Eio backend proves exact fork
   cardinality and active-fiber cleanup. `all` registers all three children,
   starts only child zero, and returns `Fail "boom"`; `all_settled` registers all
   three, runs all bodies after registration, and materializes the first error.
   A finite no-yield case pins that admission does not imply preemption.
3. **Breaking changelog:** `CHANGELOG.md` records both migration forms and the
   omitted-cap-eight to one-fiber-per-input behavior change.
4. **Footgun and guidance:** the registered delta is `-1/+1`. The mli and API
   guide reserve `all` for finite groups requiring full admission, direct large
   or data-derived independent prebuilt groups to `all_bounded`, and direct lazy
   mapping to `map_par`.

### Amendment prediction score

| Sealed amendment prediction | Actual | Score |
| --- | --- | --- |
| One shared promise gate serves `all` and `all_settled` without changing bounded workers | Exact; `all` opts in through `par_run_forks`, `all_settled` uses the helper directly | Hit |
| Synchronous first failure registers every `all` child and prevents unstarted tail bodies | Exact after adding the predicted gate plus a required post-gate cancellation checkpoint | Hit |
| `all_settled` registers every child, runs all bodies, and materializes the first failure | Exact | Hit |
| Full admission does not provide scheduler preemption | Exact finite no-yield Eio witness and documentation | Hit |
| M114/M126 sharpen to registration-before-body properties; direct claim/property counts stay fixed | Registration/cardinality required separate M114/M127 rows: 116 direct claims and 77 named QCheck properties | Miss |
| Footgun correction is `-1/+1` | Exact | Hit |
| Existing focused/full tests need no adaptation beyond new regressions | Pool and `Resource.auto` tests had scheduler-turn assumptions and were changed to await observable sleepers/results | Miss |

### Follow-up deviations

- Releasing the gate made every waiter runnable; Eio cancellation alone did not
  stop synchronous tails. The post-gate `Runtime_contract.check` is the minimal
  mechanism that enforces the predicted non-started-body rule.
- The generated positive barrier moved from a virtual-time watchdog to a finite
  cooperative-yield budget because the test-clock driver may advance a watchdog
  before newly runnable gated bodies receive turns. The required shared
  same-shape watchdog pair and bounded negative timeout remain intact.
- Gate scheduling invalidated tests that treated pool counters or one `yield` as
  proof that downstream sleeps/error recording had completed. Those tests now
  wait for the sleepers, results, or cached values they actually observe.
- Two backend regression call sites increase the final omission census from 106
  to 108; both are verification-only and safe-to-widen.

## Recommendation

Promote the registered split. `all` now makes its full-admission guarantee true
across synchronous Eio failure, `all_bounded` keeps the explicit coordination
caveat, and the one-fiber-per-input fan-out risk is visible at both API and
migration boundaries.
