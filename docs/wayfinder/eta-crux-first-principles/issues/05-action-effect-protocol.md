# Action injection and staged Eta effects

Type: grilling
Status: claimed
Blocked by: 02

## Question

What is the exact state-machine protocol behind the agreed rule that a
synchronous transition can stage Eta effects through a restricted context?

Decide:

- the types of the model, action, response, injection function, and transition
  context.
- whether injection returns `unit Effect.t` or supports typed responses.
- whether staged effects can inject only into the current state machine or into
  any captured injector.
- when staged effects start relative to model commit and stabilization.
- effect ordering, concurrency, cancellation, and ownership.
- how typed failures become actions or responses.
- what happens when a transition raises or violates the context lifetime.
- whether simple setters are state machines with hidden actions or a separate
  primitive.

Keep Eta effects as ordinary Eta values. Do not add a command wrapper unless a
specific invariant cannot be expressed without one.
