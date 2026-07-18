# DX-E24 Report — Contract blocked before implementation

## Summary

E24 cannot be implemented exactly as assigned in OCaml 5.2.0+ox. The fixed
signatures place optional arguments last, where OCaml cannot erase them. Literal
definitions either emit Warning 16 or, when that warning is suppressed, make
ordinary omission calls return optional-argument functions instead of
`Effect.t` values.

No production source, public interface, tests, examples, or documentation was
changed after sealing predictions.

## Evidence

Runnable fixture:

```sh
bash .scratch/research/dx/e24/contract-blocker/probe.sh
```

Observed Nix/OxCaml diagnostic:

```text
Error: This expression has type
         "?max_concurrent:int -> int list Contract.effect"
       but an expression was expected of type "int list Contract.effect"
Hint: This function application is partial,
      maybe some arguments are missing.
```

Three fixes were evaluated:

| Attempt | Result | Verdict |
|---|---|---|
| Literal optional-last definitions | Warning 16: options cannot be erased | Does not provide the requested calls |
| Move optionals before a positional argument | Omission works; implementation does not match the fixed interface arrow order | Requires contract authorization |
| Suppress Warning 16 | Interface compiles; ordinary calls are partial | Reject; unusable/silent workaround |

A final `unit` would be compilable but changes every requested call. Explicit
`?arg:None` at every omission is likewise not the beautiful optional-argument
API specified by the mission.

## Separate `Schedule.t` verdict

**Hold.** Independently of the optional-last blocker, slimming `Schedule.t`
exposes a tap use that the fixed E24 observers cannot express:
`Resource.auto` accepts and drives a hook-bearing schedule in its refresh daemon.
Its tap runs before a schedule step and its failure fails the driving effect.
The only existing callback, `?on_error`, observes loader failures instead.

Evidence:

- `lib/eta/resource.mli:12-29`
- `lib/eta/resource.ml:90-110`
- `test/core_common/resource_common_suites.ml:217-243`

No workaround was added, per the one-pager's explicit hold trigger.

## Gates / parity / review

The requested production gates and parity suite were not run because no E24
implementation exists. An unchanged baseline green run would not be evidence
for the new API. The E24 runtime red-team probes and A/B review packet likewise
depend on a compilable new contract and remain ungenerated.

## Predictions score

Runtime/census/footgun predictions remain **unscored** because the experiment
did not reach implementation. The sealed prediction that slimming should hold
if a non-expressible tap use appears was triggered by `Resource.auto`.

## Required decision

Authorize both of these before resuming:

1. OCaml-erasable arrow order, with optional arguments before a following
   positional argument while retaining the desired complete call spelling.
2. An observer contract for non-`Effect.retry` / non-`Effect.repeat` schedule
   drivers, or an explicit decision to keep hook-bearing `Schedule.t` for E24.

Recommendation: **block E24 as written; hold `Schedule.t` slimming separately.**
