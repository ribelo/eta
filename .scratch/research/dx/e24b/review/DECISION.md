# DX-E24b follow-up decision record

## Decision

**Accept D as a deletion proposal; retain A only as the correct interim ownership
contract.** Structural taps are coherent and A is the only tested ownership model
that preserves their branch/phase placement. Eta nevertheless has zero
production/example producers, and ordinary operation instrumentation covers the
common attempt-observation story. The earlier permanent-retention wording is
withdrawn.

No runtime deletion lands in this follow-up. The exact cross-cutting slice is in
`DELETION_PROPOSAL.md`. Until it lands, custom drivers must follow the documented
suspension contract and the two new named fixed-shape law tables.

## Complete current surface

| Surface | Count / location | D effect |
| --- | --- | --- |
| Hook producers | 2: `Schedule.tap_input` / `tap_output` | Remove |
| Effect operations | 3: `retry`, `retry_or_else`, `repeat` | Two-parameter schedules; direct step |
| Resource operations | 1: `Resource.auto` | Two-parameter schedule; direct step |
| Stream operations | 4: `from_schedule`, `schedule`, `repeat`, `retry` | Two-parameter schedules; direct step |
| Production interpreters | 3 helpers serving 3 + 1 + 4 operations | Remove |
| Public suspended protocol | `Hook`, `step_plan`, `step_with_hooks` | Remove |
| Explicit no-hook signatures | 2 HTTP retry entry points | Remove marker |
| Public tap promises | 6 across Effect/Resource/Stream docs | Rewrite |
| Pre-E24b producers | 12 constructions / 4 test files; zero shipped/example | Remove/replace tests |

`Eta_js` only re-exports Schedule. It has no separate interpreter.

## Suspension and observability matrix

“Inside” is `wrapper (tap base)`; “outside” is `tap (wrapper base)`.

| Requirement | A — current | B — driver observers | C — tested variants | D — proposal |
| --- | --- | --- | --- | --- |
| Structural pre/post | Exact branch/phase-local hooks, including `Done` | Top-level driver observers cannot represent them; structural observers can only by restoring policy-owned placement | Retain/bundle A's plan or lose boundary | Delete capability |
| Resume | Interpret in order; resume exactly once after success | Structural form needs same rule | Bundled interpreter owns it | No suspension |
| Abandon/multiple call | Abandon publishes nothing; closure is non-linear, so duplicate calls repeat tentative evaluation and violate contract | New protocol must define publication | Tested packaging is not linear | Not applicable |
| Failure/publication | `Complete` alone publishes; failure/raising resume retains original driver | All eight APIs need equivalent semantics, though one helper may centralize it | Same if plan remains | Not applicable |
| Partial effects | Prior successful hook effects remain and repeat on retry | Same for multi-observer protocol | Same | Operation semantics only |
| Cancellation | Contract abandons; Effect interruption is executable. Resource/Stream-specific cancellation remains untested | Driver-owned | Interpreter-owned | No hook cancellation |
| Tap asymmetry | Input failure precedes inner evaluation; output failure follows tentative computation but precedes publication | Coarser top-level analogue only | Requires retained plan | Removed |
| `modify_delay` / `while_output` | On tested `Continue` paths when the callback runs: input tap first; output tap inside first, outside last | Outer decision only | No tested improvement | Removed |
| `jittered` | On tested `Continue` paths when a draw runs: input tap first; output tap inside before draw, outside after | Jittered outer decision only | No tested improvement | Removed |
| `named` / telemetry | Name affects `pp` only. No automatic tap telemetry; hook effects may emit their own | Callback-owned | Interpreter-owned | Operation instrumentation |
| No-hook path | Direct and statically discriminating | Binary type with driver contracts | Tested variants do not simplify cleanly | Universal direct step; marker gone |

## Candidate D

Executable `d-surface.sh` confirms a real reduction: 2 tap vals, 1 Hook
constructor, 2 suspended entry points, 3 interpreters, 8 ternary operation
signatures, 2 no-hook annotations, and 6 explicit behavior promises. The named
integration `retry attempts can be observed without schedule taps`
proves the actual Effect recipe. `d_recipe.ml` proves the custom-driver analogue
and that it cannot recover `and_then` branch-local events. Resource/Stream
recipes remain partial guidance rather than parity fixtures.

Recipe quality is 4/5 for Effect/custom attempt logging, 2/5 for Resource/Stream,
and 0/5 for exact structural parity. D knowingly gives up the final row. A demand
signal that would reverse D is a shipped producer, concrete external structural
use, or an observability integration that requires schedule-local placement.
None is present.

## Candidate statuses

| Candidate | Status | Exact scope |
| --- | --- | --- |
| A | **CONDITIONAL** | Correct ownership model while taps remain |
| B | **REJECTED AS TAP PARITY** | Top-level callbacks remain possible; they are not structural replacements |
| C | **TESTED VARIANTS REJECTED** | They fail or add surface; the broad family is not declared dominated |
| D | **ACCEPTED AS FOLLOW-UP PROPOSAL** | Delete taps/hook channel and document operation recipes |

## Current contract evidence

- `Schedule fixed-shape ownership table preserves and_then hook order and withholds publication on failure`
- `Schedule fixed-shape suspension table exposes non-linear resume failure replay and tap asymmetry`
- `Schedule fixed-shape wrapper table orders hooks and Schedule.named emits no telemetry`
- Effect integrations: `schedule tap interruption is preserved` and
  `schedule tap_output interruption is preserved`

E22 rows M97–M112 and R102 register the new law-bearing prose. Current totals are
117 direct claims, 102 external claim clusters, and 66 unique qcheck properties.

## Verdict diary pointers

- V-DX-E24B-006 — D assessed and accepted as the production follow-up.
- V-DX-E24B-007 — earlier permanent-A verdict superseded; A is conditional.
- V-DX-E24B-008 — current custom-driver contract accepted and tested.

Full evidence, counterevidence, uncertainty, and “would change if” fields are in
`../journal.md`.

## Verification

Native `@install`, full tests, shipped tests, focused core/laws, mainline OCaml
5.4.1 `@install`/laws, `@doc`, and the full red-team packet pass. Independent
content review reports no remaining blocker. Exact commands are in
`../report.md`.
