# DX-E36 follow-up 1 micro-predictions

Sealed before follow-up implementation. The original `journal.md` remains
immutable.

## F1

Publication-order linearization is implementable by the existing single-consumer
terminal-exit stream and matches `par`'s observation model. Prediction: wording
and test names need only add the explicit `par` correspondence; no runtime work.

## F2

The old supervised structure ran
`finally (cancel_child_effect child) use`. If background cancellation triggered a
cleanup failure, `cancel_child_effect` returned the complete loser cause and
`finally` rendered that entire cause as the cleanup diagnostic:

- body success -> `Cause.Finalizer (Finalizer.Suppressed (Interrupt, cleanup))`;
- body typed failure -> `Cause.Suppressed (Fail body, Finalizer.Suppressed (Interrupt, cleanup))`;
- body defect -> `Cause.Suppressed (Die body, Finalizer.Suppressed (Interrupt, cleanup))`.

Prediction: the candidate differs because its use-winner branch extracts only
the cleanup-finalizer subtree. Discriminating tests will expose that difference;
the smallest parity adjustment is to render the complete non-clean loser cause,
while continuing to erase a cancellation-only loser.

## F3

Prediction: both current substrates publish the loser exit after cancellation,
because the child catches cancellation into an `Exit` before calling the runtime
stream handoff, and the enclosing switch joins children before arbitration
assembly. A delayed loser-finalizer regression will pass natively and on jsoo.
If either substrate loses the handoff, the smallest fix is a protected stream-add
commit window around only terminal publication.
