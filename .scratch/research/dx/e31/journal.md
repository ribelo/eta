# DX-E31 Journal — `[@@eta.trace]` promote-trigger measurement

Branch: `research/dx-e31-eta-trace-trigger`
Decision: Does E10's pre-registered trigger — “reviewers still ask for it after E7/E8” — fire?

## Predictions (sealed)

Sealed before the E31 census, post-E10 forcing-function analysis, cohort memo,
or report. This file will not be edited after the seal commit; wrong predictions
remain evidence.

### Census prediction

| Measure | Prediction |
| --- | ---: |
| Exact `Effect.fn __POS__ __FUNCTION__` sites in the fenced directories | **4** |
| Files containing those sites | **2** |
| Change from E10's recorded census | **−1 site / −1 file** |
| Consumer-shaped application sites | **0** |
| Framework/test machinery sites | **4** |
| Sugar-eligible sites | **4** |

I expect all four sites to be syntactically eligible for E10's function-binding
forms, but to exist as parity/observability/diagnostic machinery rather than as
consumer demand. Eligibility therefore will not count as a forcing function.

### Forcing-function and cohort prediction

- No promoted experiment since E10 will establish a structural need for
  definition-site trace sugar.
- E8 will be the only material directional change and will reduce demand by
  absorbing named typed-result leaf boilerplate.
- The independent cohort will **not explicitly ask** for function-level trace
  sugar after seeing the neutral census and forcing-function analysis.
- Therefore the pre-registered trigger will **NOT FIRE**, and E10's outcome will
  be **KILLED**, with no code change.

### Surface and footgun delta prediction

For the follow-up that would occur only if FIRE won, E10's rule permits one
spelling. Relative to the current tree I predict:

| Measure | NO-FIRE | FIRE follow-up |
| --- | ---: | ---: |
| Function-level sugar forms | +0 | +1 |
| Core `Effect` values | +0 | +0 |
| PPX rejection/diagnostic surface | +0 | +1 form-specific path |
| Semantic footguns | +0 | +2 |

The two predicted semantic footguns for a promoted spelling are (1) readers may
infer that the form lifts an ordinary OCaml body into `Effect.t`, although it
only wraps an already-effectful body, and (2) readers may infer one span per
recursive definition, although result-position wrapping yields one span per
recursive call. These are comprehension costs, not claims of technical
incorrectness.

### What would falsify the prediction

The trigger fires only if the cohort explicitly asks for one spelling despite
this evidence. A forcing function would also weaken the NO-FIRE recommendation
if a post-E10 experiment makes repeated definition-boundary `fn` wrapping
structurally necessary rather than merely convenient.
