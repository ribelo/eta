# DX-E24b candidate D — deletion proposal

## Decision

Delete structural schedule taps and the hook channel in a dedicated follow-up.
This supersedes the earlier “permanent” retention conclusion. A remains the
correct ownership model while the feature exists, but the repository has no
production, example, or documentation recipe that constructs a tap. The common
attempt-level observation story has an ordinary-code recipe. D accepts losing
all schedule-local effect boundaries, with branch/phase-local events as the
strongest example; none of those boundaries has demonstrated production demand.

This packet is a proposal, not the deletion implementation. DX-E24b follow-up 1
changes only the current contract prose/tests and records the deletion plan.

## Exact deletion slice

1. Change `Schedule.t` and `Schedule.driver` from three parameters to two.
2. Remove `Schedule.tap_input`, `Schedule.tap_output`, the internal tap nodes,
   `Schedule.no_hook`, and the public `Schedule.step` type with its
   `Hook`/`Complete` constructors. Remove internal `suspended`, `Return`,
   `Run_hook`, `bind_suspended`, `map_suspended`, and `run_suspended`. Generalize
   the existing direct `step` and `next` values to every two-parameter driver;
   `step` continues returning `(decision * driver)`.
3. Remove `step_plan` and `step_with_hooks`; make Effect, Resource, and Stream
   use the direct step across their 3 + 1 + 4 schedule-driven operations.
4. Change those eight public operation signatures to two-parameter schedules and
   update Stream's four internal schedule constructors and four fold functions.
   Remove the `no_hook` marker from the two HTTP retry signatures and from
   `lib/http/client/retry.ml`'s internal `packed_schedule`.
5. Remove or rewrite the six explicit tap-behavior promises in Effect, Resource,
   and Stream interfaces.
6. Remove all 25 current tap constructions: the 12 pre-E24b behavior fixtures,
   6 original ownership-table constructions, 6 follow-up suspension/wrapper
   constructions, and the output-cancellation integration. Replace only
   operation-level behaviors still required. Delete E22 M65–M67, M95–M105,
   M112, R96, and R102; split/rewrite the tap-specific portions of R80/R100.
   Preserve M106/M107/M109–M111 for surviving `Schedule.named`, remove M108's
   hook-order claim, and replace the tap-based combined property with a small
   no-hook `named` property. Preserve M68 (`next`), R94 (`Continue` delay), and
   R95 (`jittered` random), then recensus.
7. Update `Eta_js` through its existing Schedule re-export; no separate JS
   implementation exists.
8. Change the non-tap ternary annotation in
   `test/core_common/properties_common_suites.ml:12` to the two-parameter type.
9. Rework or remove the old C fixtures (`c_hide_hook_negative.ml`,
   `c_pack_interpreter_positive.ml`) and `no_hook` positive/negative fixtures,
   including their runners, so `redteam/run-all.sh` remains meaningful after
   deletion.
10. Update the durable status summary in `docs/research/dx.md`: when deletion
    lands, it must no longer describe E24b as a pending permanent-retention
    question.

`redteam/d-surface.sh` asserts these surface facts. No compatibility shim or
deprecation path is proposed.

## User recipe after deletion

- **Effect retry/repeat:** instrument the source effect itself before passing it
  to `retry`/`repeat`. This observes every process attempt, including the initial
  one. The named integration test `retry attempts can be observed without
  schedule taps` executes the real `Effect.retry` recipe; `redteam/d_recipe.ml`
  proves the equivalent custom-loop recipe.
- **Resource.auto:** instrument `load`; use an application-owned counter if seed
  and refresh attempts need distinct labels. This observes loads, not terminal
  schedule exhaustion.
- **Stream.retry:** place `Stream.tap_error` on the source *before* `Stream.retry`,
  or instrument the source directly; a tap outside retry sees only the final
  failure. For `Stream.schedule`/`from_schedule`, use `Stream.tap` for emitted
  values. These recipes cannot observe the terminal non-emitted schedule
  input/output.
- **Custom drivers:** observe immediately around direct `Schedule.step` calls.
  This yields top-level input/decision observations only.

Rating: **good (4/5)** for “log every Effect attempt”; **partial (2/5)** across
Resource/Stream because seed, emission, and schedule-step boundaries differ;
**no parity (0/5)** for all schedule-local effect boundaries. Deletion removes
top-level terminal `Done` observation, access to policy-generated outputs such as
delay-series values, effects at the policy-evaluation/driver-publication
boundary, hook failure/cancellation as an advancement veto, and arbitrary
custom-effect-system interpretation through `step_plan`. Branch/phase-local
events within one composed step are the strongest example, not the whole loss.
D accepts every listed loss because none has demonstrated production demand.
Resource/Stream recipes are guidance inferred from their current public
operations, not compile-checked parity fixtures in this packet.

## Demand gate that would reverse D

Reconsider before implementation only if evidence supplies at least one of:

- a shipped non-test Eta producer of `tap_input`/`tap_output`;
- a concrete external adoption report with code requiring schedule-local rather
  than process-level observation; or
- any demonstrated schedule-local effect requirement with no ordinary recipe,
  including terminal-output handling, policy-output access, a failure/cancellation
  advancement veto, custom-effect-system interpretation, or observability.

Tests of the feature, public signatures that merely accept it, and existing API
prose are behavior evidence, not demand evidence. None of the demand signals is
present in this repository today.

## Required implementation gates

- native `@install`, full tests, and `eta-oxcaml-test-shipped`;
- mainline `@install` and full shipped/JS coverage because `Eta_js` re-exports
  Schedule;
- `@doc` after all interface edits;
- a compile-negative fixture proving old ternary/tap usage fails, plus a positive
  two-parameter custom-driver and HTTP signature fixture.
