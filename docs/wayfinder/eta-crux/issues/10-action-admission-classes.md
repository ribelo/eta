# Action admission classes: droppable and guaranteed

Type: grilling
Status: open
Blocked by: 04

## Question

**This reopens a recorded decision.** The action queue is bounded: non-owner overflow becomes
an admission failure reported to the adapter, owner-domain producers are suspended until
capacity frees, and stop drops queued actions. There is no way to say "this action may be
coalesced" as distinct from "this action must never be dropped".

This is a genuine departure from both references — in Elm and Crux, delivery of a dispatched
message is unconditional — and the departure is invisible at the type level. A dropped
high-frequency action such as pointer move or an activity ping is fine; a dropped terminal
action such as process-settled or request-completed is an unrecoverable hang. Which is which
is application knowledge the adapter cannot infer, so today every adapter must keep a shadow
queue in front of ours, which is the thing the bounded queue was meant to avoid.

Decide:

- Whether an admission class exists, with at least a droppable and a guaranteed class.
- Behaviour while the queue is full: reject or coalesce droppable-class actions, and admit
  guaranteed-class actions from reserved capacity.
- A distinct saturation failure when guaranteed reserved capacity is exhausted, never a
  silent discard.
- Whether shutdown reports the count of dropped queued actions in its result.

Blocked by ticket 04 so that the failure taxonomy is decided once and shared across ask
replies, capability responses and admission failures.
