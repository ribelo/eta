# DX-E36 follow-up 2 micro-predictions

Sealed before follow-up-2 implementation. Earlier journals remain immutable.

## X1 — filter rule

Prediction: the smallest correct change is to classify only an interrupt-only
loser as clean and otherwise attach `Cause.finalizer_of_cause` of the complete
loser. The existing extraction helper will be deleted. This restores the old
interrupt wrapper around a cleanup failure without changing winner selection.

## X2 — discriminating parity

Prediction: exact compact structural renderings for old and new will match in
all three use-winner cases: outer `Finalizer` after success, outer `Suppressed`
with a typed body failure, and outer `Suppressed` with a body defect. A real
string renderer will distinguish `Cleanup_failed` from body errors.

## X3 — registry

Prediction: R143 will become truthful after X1/X2. R141 needs only narrower
evidence wording because its test pins publication-order arbitration, not a
comparative `par` execution. Registration pointers will move mechanically.

## X4 — weaker evidence

Prediction: jsoo can hold a cancellation-triggered loser finalizer with an
async gate and prove the parent remains unresolved. A background-winner/body-
cleanup-failure test will show the background cause as primary with the complete
body cancellation/cleanup cause attached. The observable contract should say
finalizers run exactly once, not claim an unobservable count of `fail_scope`
calls.
