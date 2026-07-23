# `Effect.retry` before/after matrix

| Source exit / policy path | Before | After |
|---|---|---|
| Success | Return success | Unchanged |
| Bare `Fail e`, predicate rejects | Return `Fail e`; no schedule step | Unchanged |
| Bare `Fail e`, schedule continues | Sleep and retry | Unchanged |
| Bare `Fail e`, schedule exhausts | Return `Fail e` | Unchanged |
| Typed-only composite, predicate accepts, schedule continues | Return composite immediately; policy not consulted | Pass first typed failure to predicate and schedule, then retry |
| Typed-only composite, predicate rejects | Return original composite without consulting predicate | Predicate sees first typed failure; return original composite |
| Typed-only composite, schedule exhausts | Return original composite without stepping schedule | Schedule sees first typed failure; return original composite |
| Composite containing defect | Return original composite; no retry | Unchanged; shared boundary refuses and preserves it |
| Composite containing interruption | Return original composite; no retry | Unchanged; shared boundary refuses and preserves it |
| Suppressed/finalizer diagnostic | Return original cause; no retry | Unchanged; shared boundary refuses and preserves it |
| Raw empty composite variant | Return the empty cause | Unchanged; no typed failure means no policy and the original cause passes through |

The behavior change is limited to typed-only composites: policy is now
consulted and may cause retries. Selection of the first failure is a policy
input decision, not a terminal-cause collapse.
