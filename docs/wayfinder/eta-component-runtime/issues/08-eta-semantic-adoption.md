# Eta semantic adoption

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 04

## Question

Which Cordis semantic guarantees will Eta adopt, strengthen, weaken, or reject?

Define the exact system boundary and observational equivalence. State the
assumptions for independence, acyclic dependencies, finite activation, provider
identity, and recovery. Separate required guarantees from optional mechanisms.

The answer must cover both local and global temporal and spatial
composability. It must also state how Eta handles a guarantee that cannot hold
for an external emission.

## Answer

Eta adopts the complete Cordis semantic model at its stated conditional
strength. Eta strengthens the lifecycle rules that the runtime can enforce. It
does not claim that the runtime can prove arbitrary native code correct.

### System and observation boundary

Recovery covers state that the component runtime mediates:

- typed provision operations and their outcomes.
- requirement presence and absence.
- provider-episode identity.
- the committed provider view.
- the current component lifecycle outcome.
- tracked registrations.
- component-owned state behind declared coeffect operations.

Each typed coeffect key defines its observable operations and value
equivalence. Runtime observations add provider presence, provider-episode
identity, lifecycle state, and retained causes.

A provider episode has one opaque runtime identity. The identity has a
one-to-one association with one component instance and one activation
generation. Each reactivation creates a new provider episode. Equal values
from different episodes do not make provider views equal.

Recovery does not require physical-state equality. It also excludes allocation
identity, diagnostic history, and external-emission history. Terminal
confluence compares committed state, not execution traces.

External emissions are permitted but remain outside the recovery guarantee.
An adapter can withhold an emission until commit. Compensation has different
semantics and requires separate laws.

### Local temporal contract

Each tracked mutation must supply a valid recovery witness before its
activation commits. Successful witnesses compose sequentially in reverse
registration order.

Activation stages registrations and provisions. Partial activation failure
recovers all successful tracked mutations and publishes none of the staged
state.

When a provider target changes, the runtime closes admission before it requests
cancellation. It then waits for owned work and cleanup to settle. Work from a
stale provider episode cannot publish. If stale work committed a tracked
mutation, its recovery witness still runs.

Activation failure remains local to the component instance. The runtime retains
the complete Eta cause. It retries only after a defined target change or an
explicit request.

Recovery equivalence requires every recovery operation to terminate
successfully. A completed recovery failure settles in a recovery-failed state.
The settlement fence returns the cause, and no recovery-equivalence claim
applies. A recovery operation that does not terminate keeps the lifecycle
nonquiescent.

### Local spatial contract

A component declares typed requirements and provisions before activation.
Dynamic dependency access uses only declared keys from the committed provider
view. Undeclared or inactive access fails.

Activation starts only when all requirements resolve to active provider
episodes. A successful activation stages exactly its declared provisions.
Missing or undeclared provisions prevent publication.

One committed provider episode can own a key in one isolation realm. A
conflicting publication fails before commit. Multiplexing requires an explicit
broker component.

Isolation changes realm-specific provider resolution. Interception changes how
a provision is used. Interception does not change provider availability or
provider-episode identity.

### Global temporal contract

A provider episode starts before each consumer episode that resolves to it. The
provider episode outlives those consumer episodes.

Provider withdrawal first closes admission for new consumers. The runtime then
retires and settles existing consumers before it runs provider recovery.
Consumers use their committed provider view during teardown.

Global recovery requires cross-instance independence. Operations at different
keys must not affect each other. Shared-key operations must commute and preserve
outcomes, recovery witnesses, and continuations. Executable laws provide
evidence for these obligations.

Noncommutative operations require an explicit owner, accumulator, or dependency
order. Eta makes no out-of-order global recovery claim for operations that do
not satisfy the independence laws.

### Global spatial contract

The committed provider graph must be acyclic. The runtime reports a cycle and
refuses to commit that graph.

A provider-episode change deactivates and reactivates each affected consumer.
This rule applies even when the old and new provider values are equivalent.

Under the stated assumptions, lifecycle schedules with the same stopped
orchestration input converge to the same terminal committed state as a fresh
assembly. Diagnostic traces and external-emission histories can differ.

### Validity envelope

Local recovery requires:

- a valid recovery witness for each successful tracked mutation.
- key-defined observational equivalence.
- mediation of all state included in the recovery claim.
- sequential reverse-order recovery.
- successful termination of each recovery operation.

Global recovery also requires the independence laws. Progress also requires a
finite component graph, terminating activation and recovery work, and a pause
in orchestration input.

Confluence additionally excludes terminal activation and recovery failures.
Eta enforces acyclic committed graphs, unique providers in each realm, and
total declared provisions. These rules are not caller assumptions.

If an assumption does not hold, Eta still preserves lifecycle ownership,
admission fences, settlement, and causes. Eta does not claim the affected
recovery, progress, or confluence result.

### Required protocol and optional mechanisms

The design must preserve:

- provider-episode generations.
- staged publication and an explicit commit point.
- one committed provider view per active consumer.
- an admission fence before cancellation.
- dependent-first withdrawal and settlement.
- sequential recovery accumulation.
- duplicate-provider and cycle validation.
- cause-preserving lifecycle outcomes.

An implementation can replace one of these protocol elements only with an
observationally equivalent mechanism and matching executable laws.

Eta scopes continue to own lexical resources. The component context owns
provider availability, long-lived registrations, desired-state component
instances, and lifecycle coordination across activations. The design does not
add another effect algebra.

The exact state names, iterator form, context representation, notification
primitive, scheduler, storage layout, and Eio adapter are later design choices.
Cordis generators, JavaScript proxies, recursive context objects, string keys,
and persistent fiber UIDs are not Eta requirements.
