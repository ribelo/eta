# DX-E24c report — schedule-hook channel deletion

## Recommendation

**PROMOTE — E24C READY FOR REVIEW.** The hook channel had no shipped producer,
the exact deletion contract is implemented without a compatibility path, every
surviving schedule law is green, and both native and mainline/JS gates pass.

## Implementation

`Schedule.t` and `Schedule.driver` now have two parameters. The tap constructors,
tap nodes, `no_hook`, suspended public step type, `step_plan`,
`step_with_hooks`, and the internal suspended interpreter are deleted.

The engine is direct mutual recursion. `step_state` returns a decision and next
state; `step_phase` converts terminal decisions into a finished phase; `step`
publishes the next driver directly. `both` and `either` preserve left-to-right
child stepping and their max/min delay rules. `and_then` preserves the existing
same-call handoff from a terminal left phase into a fresh right phase.
`modify_delay`, `while_output`, `jittered`, and `named` wrap the directly returned
decision/state without an intermediate protocol.

Effect's three operations, Resource's one operation, and Stream's four
operations now call direct `step`. The Stream GADT/folds and the two HTTP retry
signatures use binary schedules. `Eta_js` continues to use its existing Schedule
re-export.

## Gates

All contract commands passed on the final production implementation:

| Gate | Result |
| --- | --- |
| `nix develop -c dune build @install` | PASS |
| `nix develop -c dune runtest --force` | PASS |
| `nix develop -c eta-oxcaml-test-shipped` | PASS |
| `nix develop -c dune build @doc` | PASS |
| `nix develop .#mainline -c dune build --build-dir=_build-mainline @install` | PASS (OCaml 5.4.1) |
| `nix develop .#mainline -c dune runtest --build-dir=_build-mainline test/laws test/js_jsoo test/cache_jsoo test/signal_jsoo --force` | PASS |

The mainline JS gate passed `eta_jsoo`, `eta_js_jsoo`, `eta_cache_jsoo`, and the
signal JS suite. The existing JS integer-overflow warnings were non-failing and
unrelated to this change.

Additional evidence:

- `test/laws`: 62 named properties pass under OxCaml and mainline OCaml.
- `test/core_eio`: 566 tests pass, including
  `retry attempts can be observed without schedule taps`.
- `test/http`: 359 tests pass, including the explicit two-parameter Schedule
  fixture for both HTTP retry entry points.
- `test/type_errors`: snapshots reject ternary `Schedule.t` and
  `Schedule.tap_input` with clear compiler errors.
- `.scratch/research/dx/e24b/redteam/run-all.sh`: PASS post-deletion.
- `redteam/e24c/run-all.sh`: PASS.

## Law preservation and E22 surgery

No surviving schedule expectation changed. The E22 surgery removed exactly
M65–M67, M95–M105, M108, M112, R96, and R102; R80 and R100 now state only their
surviving operation behavior. M68, R94, and R95 remain. M106/M107/M109–M111 are
covered by `Schedule.named changes only pp and emits no logs spans or metrics`,
which compares complete plain/named driver traces through terminal `Done`.

| E22 metric | Before | Actual after |
| --- | ---: | ---: |
| direct mli claims | 117 | 101 |
| registered external rows | 102 | 100 |
| model claims | 2 | 2 |
| covered registry rows | 219 | 201 |
| unique named qcheck properties | 66 | 62 |
| Schedule direct / external / model rows | 24 / 4 / 2 | 8 / 2 / 2 |

The safety-net attack committed a compiling `and_then` regression as `22d43b25`.
The named phase-order law failed and shrank to `(1, 0)`; `f73e45f1` reverted the
regression. Tests and expectations were unchanged. Evidence is in
`redteam/e24c/invariant-break-output.txt`.

## Census and footguns: prediction vs actual

| Metric | Predicted | Actual |
| --- | ---: | ---: |
| `Schedule.t` parameters | 2 | 2 |
| `Schedule.driver` parameters | 2 | 2 |
| public tap values | 0 | 0 |
| suspended stepping values | 0 | 0 |
| direct stepping values | 2 generalized | `step` and `next`, generalized |
| hook-accepting public operations | 0 | 0 |
| production hook interpreters | 0 | 0 |
| footgun delta | −1 / +0 | −1 / +0 |

The Schedule cluster lost hooks, suspension, hook interpretation/resumption,
publication discipline, and the `no_hook` distinction. Policy, driver,
decision, metadata, composition, random injection, and direct stepping remain.
The deleted non-linear resume/failure/publication protocol was one footgun
cluster; no replacement protocol or callback hazard was added.

The prediction expected 20–30 changed files. The actual branch delta after the
initial handoff was 47 files: the production migration remained concentrated in
10 library files, while exact E22 span recensus, two fixture locations, durable
red-team evidence, review documents, and historical runner cleanup made the
repository-wide count larger. The prediction was directionally correct about
mechanical dominance but underestimated evidence-file spread.

## Red-team outcomes

1. **Old surface fails loudly — PASS.** The compiler reports that `Schedule.t`
   expects two arguments and that `Schedule.tap_input` is unbound.
2. **Ordinary recipe survives — PASS.** Instrumenting the source observes all
   Effect retry attempts, including the initial attempt.
3. **A surviving law catches engine damage — PASS.** The committed/reverted
   `and_then` mutation compiled and failed the named phase-order law.

The E24b C/no-hook fixtures were removed because their types no longer exist;
its `run-all.sh` now checks the landed binary surface and ordinary recipe.

## Documentation and accepted loss

Public interfaces and `docs/api-dx.md` direct Effect users to instrument the
source, `Resource.auto` users to instrument `load`, Stream users to place
`tap_error` before retry or use `tap` for emissions, and custom drivers to
observe around `Schedule.step`.

These are not parity replacements. Terminal non-emitted values,
policy-generated outputs, policy-evaluation/publication vetoes, custom hook
interpretation, and branch/phase-local events are no longer expressible. This is
the exact loss accepted by the E24b decision.

## Deviations

There is no semantic deviation from the proposal. Two fixture-placement choices
use existing repository gates rather than inventing new infrastructure:

- negative examples live in `test/type_errors` and use its compiler snapshot;
- positive binary-driver and HTTP-signature fixtures are named tests in the
  existing core and HTTP suites.

The invariant attack triggered both the intended `and_then` phase-order law and
the surviving terminal-Done-delay law because the deliberate corruption changed
both output order and termination. The required named-law detection still held,
and the regression was reverted.
