# Reactive resolution and withdrawal

Type: prototype
Status: resolved
Blocked by: 08, 10, 12

## Question

How does the runtime resolve providers and react when a required provider
appears, disappears, or changes identity?

Prototype dependency satisfaction, committed provider views, notification,
replacement, cycles, and a provider with several dependent levels. Include a
dependent whose asynchronous teardown still needs the departing provider.

Decide the withdrawal guard and prove that it releases. State whether duplicate
providers fail at admission or use another explicit mechanism.

## Answer

Use immutable provider views, targeted topology notifications, and direct
provider-episode leases. One serialized context coordinator owns resolution and
all lifecycle commands.

### Resolution and notification

The provider index is keyed by an isolation realm and a typed coeffect key. A
discoverable entry identifies one active provider episode.

The runtime resolves all declared requirements as one operation. Activation
starts only when every requirement resolves to a discoverable episode. The
resolved values and episode identities form one complete provider view.

The consumer keeps this view for its complete activation generation. The view
does not change during activation, ordinary work, or teardown. Component code
receives the resolved requirement value, not a registry or provider callback.

A provider visibility change increments a private topology revision. The
coordinator queues only consumers that declare an affected key in the affected
realm. Each queued consumer recomputes its complete target view.

The topology revision is a notification token. It is not provider identity and
does not cause a restart by itself. A changed episode identity or missing
requirement changes the consumer target.

A waiting consumer activates when its complete target becomes available. An
active consumer settles when its target becomes unavailable or changes
identity. Changes that arrive during settlement replace the pending target.

### Provider slots and duplicate providers

A provider inventory can contain several implementations for one key. One
admitted desired target can select only one discoverable provider for each realm
and key.

The runtime rejects two discoverable candidates during desired-target
admission. The rejection occurs before lifecycle mutation. Multiplicity behind
one discoverable key requires an explicit broker component.

A retiring episode is not discoverable. It can coexist with one discoverable
successor while committed consumer views still retain it. This overlap is not a
duplicate provider.

### Withdrawal guard

Each consumer episode owns one lease for each distinct provider episode in its
committed view. Several required keys from one provider episode use one
dependency edge and one lease.

Provider withdrawal follows this order:

1. The coordinator closes admission for the departing episode.
2. The coordinator removes that episode from new resolution.
3. The coordinator closes admission for consumers whose committed views retain
   the episode.
4. Each consumer settles with its unchanged provider view.
5. Successful consumer settlement releases its direct provider leases.
6. Provider recovery starts only when its direct lease count is zero.

Direct leases are sufficient for a dependency chain. An intermediate provider
cannot settle while one of its direct consumers retains a lease. It releases
its own upstream lease only after its activation scope settles.

Thus, the guard induces dependent-first settlement without a separate
transitive counter. An asynchronous disposer can continue to use the departing
provider through its committed view.

### Provider replacement

Generations of one component instance remain serialized. A new generation of
that instance cannot start until its old generation settles.

A distinct successor instance can commit after the old episode leaves
resolution. It does not wait for the old episode lease count to reach zero.
New resolutions use the successor while old consumers retain the retiring
episode.

Each old consumer reactivates against the latest complete view after its own
generation settles. Equal provider values do not preserve the old target when
the provider-episode identity changes.

### Cycles and progress

Desired-target admission rejects a cycle in the prospective provider graph. It
does not mutate the current committed composition. A missing provider is not a
cycle and leaves the consumer waiting.

The withdrawal guard reaches zero under these conditions:

- The committed dependency graph is finite and acyclic.
- The orchestration input stops while the graph settles.
- Each affected activation and cleanup operation terminates successfully.
- Closing admission prevents new leases on each retiring episode.

Every finite acyclic graph has a retiring leaf. That leaf can settle and release
its leases. Repeating this argument in reverse dependency order releases every
guard.

A failed or nonterminating cleanup does not release its leases. The provider
remains guarded. The affected context stays degraded or nonquiescent and does
not claim successful recovery.

### Cordis relationship

The committed view and withdrawal guard transfer the paper semantics directly.
The direct lease count incrementally implements the guard over retained
consumer views that the paper defines.

The TypeScript runtime deletes the shared provider binding before notification.
It retains the provider in each consumer snapshot until dependent teardown
finishes. It waits for direct consumers, which produces the same recursive
withdrawal order.

Eta strengthens that implementation with typed keys, activation-generation
identity, explicit cycle diagnostics, complete causes, and retained leases after
failed cleanup. See [Cordis semantic contract](01-cordis-semantic-contract.md)
and [Cordis TypeScript implementation](02-cordis-typescript-implementation.md).

### Prototype evidence

The accepted prototype is on branch
`prototype/eta-component-reactive-resolution` at commit `3b858fc9`. See the
[prototype source](https://github.com/ribelo/eta/tree/3b858fc9100b487a84dbaaa19658a7f253216222/.scratch/eta-component-runtime-reactive-resolution).

The fixed traces cover provider appearance, disappearance, same-instance
replacement, distinct-provider handoff, duplicate admission, cycles, and a
three-level dependency chain. The asynchronous consumer keeps its old provider
view usable until it releases the final lease.
