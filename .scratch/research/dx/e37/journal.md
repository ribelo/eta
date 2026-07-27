# DX-E37 sealed predictions

Sealed before E37 code or public-contract changes. This file is immutable after
its sealing commit.

## Question and constraints

Decide whether the upstream-decided homogeneous `Effect.acquire_all_par`
surface can own the parallel acquire/transfer/cleanup protocol without exposing
`Effect.Expert`. The arity and heterogeneous alternatives are out of scope. The
public contract must fit in roughly ten documentation lines.

## Proof obligations and predictions

| ID | Obligation | Sealed prediction |
| --- | --- | --- |
| P1 | Admission and concurrency | Acquisitions overlap. `max_concurrent` has exact `map_par` admission semantics: default 8, at most the bound admitted, fewer for shorter input, and `Invalid_argument` for a non-positive bound. |
| P2 | Acquire failure | The first observed acquire failure propagates fail-fast. Every successfully acquired resource is released exactly once, promptly, in reverse successful-acquisition order; the body after acquisition does not run. |
| P3 | Cancellation race | Parent cancellation cancels and awaits admitted acquisitions. Completed acquisitions release once in reverse completion/registration order. An acquisition completing only after cancellation has won is cleaned in its child scope, is not transferred to the owner scope, and leaves no live fiber. |
| P4 | Successful transfer | Returned resources remain alive until the enclosing scope exits. Owner releases run in reverse successful-acquisition order after success, typed failure, defect, and interruption. |
| P5 | Release diagnostics | A release failure after owner success becomes `Cause.Finalizer`; under a typed failure, defect, or interruption it is preserved as a suppressed finalizer while the primary cause remains primary. Multiple releases continue so no later finalizer is silently dropped. |
| P6 | Result order | Successful results are returned in input order even when acquisitions complete out of order. |

## Implementation prediction

The smallest correct implementation will be an internal ownership bridge over
existing effect frames/scopes and parallel admission, with a cancellation-safe
commit point between child acquisition success and owner registration. It will
not require a new runtime-contract operation or any public `Expert` call. The
hardest disconfirming case is an uninterruptible acquisition that publishes a
resource after sibling failure/cancellation; it must stay child-owned and clean
locally rather than transfer late.

## Documentation and surface prediction

- `effect.mli` will add exactly one public value and a contract within the
  approximately-ten-line budget.
- `docs/api-dx.md` will make `acquire_all_par` the ordinary homogeneous recipe;
  the `Expert` bridge will remain only as a demoted heterogeneous/advanced note.
- Census delta: public values `+1`; public modules/types `+0`.
- Footgun delta: `-1` because homogeneous parallel acquisition no longer
  requires application use of `Effect.Expert`; no new default or fallback
  footgun is expected.

## Review prediction

Prediction: **READY FOR REVIEW**, with high confidence if all deterministic
scope/cancellation and dual-runtime gates pass. Unlike E6's killed cardinality
helpers, the name carries the parallel strategy and owns a protocol that cannot
be expressed correctly with ordinary public combinators. The likely review
challenge is whether late completion can cross the cancellation/ownership
commit point; any leak, duplicate release, dropped release diagnostic, contract
budget overflow, or need for public Expert is a stop/block result rather than a
reason to weaken the semantics.
