# Subscription reconciliation before command spawn within a tick

Type: grilling
Status: open
Blocked by: 01

## Question

The desired subscription set derives from committed state, and command spawn happens after
output observation, but the relative order of starting a newly desired subscription and
spawning a staged command from the same transition is unfixed.

The universal idiom is a single transition that both records "this work now exists", which
makes its subscription desired, and schedules the command that starts that work. If the
command can run before the subscription is live, an immediately-emitted item is lost — and
for a terminal item that is a permanently stuck application. Elm reconciles subscriptions
from the new model before running effects for the same round, and making the rule explicit
costs nothing because the desired set is already derivable from committed state.

Decide:

- That subscription reconciliation completes before any staged command of that tick spawns.
- That a subscription becoming desired in the same tick as the command that starts its
  source is live before that command begins.
- Where this sits in the tick phase order for each backend, given the plain backend has no
  settle phase.
