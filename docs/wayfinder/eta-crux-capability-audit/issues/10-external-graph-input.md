# External graph input

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04, 05, 06, 07

## Question

Does Eta Crux need a host-owned external graph input?

Check the claim that changing host state must become an action or closure-captured
construction argument. Compare graph variables, typed root inputs admitted
through the advancement fence, and the existing action pattern.

Decide whether to adopt, defer with a precise condition, or reject the
capability. If adopted, specify the API shape, ownership, identity,
stabilization rules, commit rules, and cutoff behavior. Also specify admission,
failure behavior, test controls, semantic laws, and migration effects.

## Answer

### Decision

**Reject a separate host-owned external graph-input capability.**

The reported claim is correct. Live host values enter the graph through typed
endpoint actions. Ordinary closures carry construction values.

The current capability is application-composable. This decision keeps the
existing action boundary and adds no second input path.

The supporting evidence is in the
[current baseline](../../../../.scratch/research/eta-crux-capability-audit/01-current-eta-crux-capability-baseline.md),
[decision history](../../../../.scratch/research/eta-crux-capability-audit/02-prior-decision-and-requirement-provenance.md),
[Bonsai census](../../../../.scratch/research/eta-crux-capability-audit/bonsai-public-capability-census.md),
[Eta substrate audit](../../../../.scratch/research/eta-crux-capability-audit/06-eta-substrate-capability-support.md),
and
[consumer audit](../../../../.scratch/research/eta-crux-capability-audit/07-representative-consumer-friction.md).

### Input boundary

Every live host change enters application state as an action sent through an
`Endpoint.t`. The existing ingress queue controls admission and FIFO order.

One advancement consumes one admitted action. The state-machine transition,
stabilization, rollback, commit, output, and post-commit rules remain unchanged.

A construction closure can carry an ordinary OCaml value. Pure callbacks must
not use captured mutable state as a hidden reactive dependency.

An application that needs the latest host fact stores that fact in a model. A
typed set action changes the model through the normal advancement fence.

Eta Crux adds no graph variable, root-input identity, root-input setter, cutoff,
or separate test control.

### Rationale

`Bonsai.Expert.Var` is a mutable source outside a Bonsai graph. `value` gives the
graph read-only access, while `set` and `update` change the source directly.

Bonsai observes the current variable value during stabilization. Its API does
not promise one graph transition for each write. Bonsai documents tests as the
most common use of this expert API.

That latest-value contract conflicts with Eta Crux action ordering. It can hide
intermediate writes and creates a second path for live host changes.

A typed root input that preserves every write would duplicate the existing
endpoint and advancement semantics. A new name would add public-surface cost
without adding a capability.

No examined Eta Crux consumer uses another external-input form. The small
consumer set makes absence weak rejection evidence. The semantic duplication
and the existing explicit boundary provide the primary reasons.

### Existing contracts and migration

`Endpoint.send` keeps its bounded admission and `Ingress_closed` result.
Endpoint-incarnation checks keep rejecting stale actions during advancement.

Tests continue to inject typed actions through the test handle. They need no
variable control or separate stabilization operation.

This rejection adds no API, failure variant, semantic law, test gate, or
migration work.
