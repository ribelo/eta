# DX-E24c execution journal

## V-DX-E24C-001 — sealed predictions

### Reversal gate

`redteam/d-surface.sh` and an independent `rg` census found zero shipped,
non-test producers of `Schedule.tap_input` or `Schedule.tap_output`. The only
matches under `lib/` are the two Schedule API definitions themselves. The
deletion demand gate therefore remains open.

### Migration-size prediction

- Production/API migration: the Schedule implementation and interface, three
  operation drivers, the Stream implementation/interface, HTTP retry
  implementation/interface, and the eight public operation signatures.
- Test/evidence migration: remove the 25 tap constructions and the obsolete C
  and `no_hook` probes, retain operation behavior with focused no-tap
  replacements, add one old-surface compile-negative fixture and one direct
  two-parameter-driver positive fixture, and perform the exact E22 census
  surgery.
- Documentation/research migration: update Schedule recipes and status prose,
  then add the required review packet and report. I expect roughly 20–30 files
  to change, dominated by mechanical type-arity and fixture deletion rather
  than new code.

### Engine-rewrite prediction

Replace the suspended interpreter with direct structural recursion:
`step_state` and `step_phase` return `(decision * state/phase)` directly. Each
combinator steps children in the existing left-to-right order and constructs
the same metadata, phase, and next state. `and_then` retains its same-step
handoff from a terminal left phase into the right phase. `step` publishes the
new driver directly, and `next` remains a projection over `step`.

No compatibility layer, replacement hook protocol, callback API, or new public
surface will be introduced.

### Hardest-law prediction

The highest-risk surviving laws are structural composition (`both`, `either`,
and especially same-step `and_then` handoff), followed by metadata continuity
across terminal/active phases. `modify_delay`, `while_output`, and `jittered`
are mechanically simpler but sensitive to preserving callback/random-draw
timing and `Continue`-only delay transformation. `named` should become a small
proof that only `pp` changes while stepping remains identical.

### Census and footgun prediction

| Metric | Before | Predicted after |
| --- | ---: | ---: |
| `Schedule.t` parameters | 3 | 2 |
| `Schedule.driver` parameters | 3 | 2 |
| public tap values | 2 | 0 |
| suspended protocol values (`step_plan`, `step_with_hooks`) | 2 | 0 |
| direct protocol values (`step`, `next`) | 2, restricted | 2, generalized |
| hook-accepting public operations | 8 | 0 |
| production hook interpreters | 3 | 0 |

The Schedule concept cluster should lose hooks, suspension, interpretation,
resume/publication discipline, and `no_hook`, while retaining policy, driver,
decision, metadata, composition, and direct stepping. Predicted footgun delta:
**−1 / +0**: remove the non-linear suspended-hook publication/failure protocol
without adding a replacement hazard.

## V-DX-E24C-002 — law safety-net attack

After the direct engine and 62-law baseline passed, throwaway commit `22d43b25`
made `and_then` enter its right phase on a continuing left decision. The engine
compiled. `EXPECT_FAILURE=1 redteam/e24c/run-invariant-law.sh` then failed the
named `Schedule.and_then tags every first phase output before every second phase
output` property and shrank the counterexample to `(1, 0)`. Revert `f73e45f1`
restored the good engine with no expectation changes. Evidence is committed in
`redteam/e24c/invariant-break-output.txt`.

## V-DX-E24C-003 — final actuals

All six required Nix gates passed, including mainline `_build-mainline` laws and
JS coverage. Both E24b and E24c red-team runners pass. The final census is:
`Schedule.t`/driver 3→2 parameters, tap values 2→0, suspended entry points 2→0,
hook-accepting operations 8→0, and production hook interpreters 3→0. E22 is
101 direct claims, 100 external rows, 2 model claims, 201 covered rows, and 62
named properties. The predicted footgun delta of −1/+0 is confirmed.

The 20–30-file migration prediction missed high: the branch delta after initial
handoff is 47 files because exact E22 span recensus, fixture placement, review
artifacts, and historical red-team cleanup spread the mechanical deletion. The
engine-risk prediction hit: `and_then` was the most sensitive invariant, and its
named law rejected the committed mutation. No surviving semantic law changed.

Recommendation: **PROMOTE / E24C READY FOR REVIEW**. Full details are in
`report.md`.
