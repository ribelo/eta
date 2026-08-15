# Isolation and interception

Type: prototype
Status: resolved
Blocked by: 02, 10, 13

## Question

How will Eta represent scoped coeffect isolation and interception without
weakening typed access or reactive provider identity?

Prototype derived contexts, realm identity, provider lookup, interception
metadata, and realm reassignment. Include two instances that use one logical
key but resolve different providers.

Decide which operations trigger reactivation and which operations change only
future access behavior.

## Answer

Use typed derived contexts, opaque isolation realms, typed interception
metadata, and transactional realm reassignment. One serialized context
coordinator owns all mutation.

### Derived contexts and realms

A derived context inherits realm and interception mappings from one parent. A
local mapping shadows its inherited mapping for one typed coeffect key.

Public derivation leaves the parent unchanged. The runtime can use private,
stable slots while it reconciles an installed desired-state entry. Applications
and component activation code cannot mutate these slots.

Each realm has opaque, generative identity. The provider index uses one typed
coeffect key and one realm. Thus, separate realms can contain providers for the
same key.

An unisolated key resolves in the root realm for that key. Two different typed
keys never alias only because they use one realm name. This `(key, realm)` index
matches Cordis runtime behavior and preserves Eta typing.

### Typed interception

An interceptable coeffect defines:

- one typed metadata identity.
- one empty metadata value.
- one associative merge operation with that empty value as its identity.
- one wrapper that applies an operation-entry metadata snapshot.

A requirement can carry component-declared metadata. Contexts can add outer and
inner metadata for the same coeffect. Resolution merges metadata in this order:

1. Component-declared metadata.
2. Outer context metadata.
3. Inner context metadata.

The runtime folds metadata in this exact order. The algebra defines the
result. It need not be right-biased.

A requirement with no declared metadata uses the empty value. It still receives
context interception. Thus, a component cannot bypass interception by omitting
metadata.

The runtime gives activation code an ordinary typed value. It does not give
activation code a context, key, registry, or metadata reader.

The runtime wrapper samples one immutable merged snapshot at each coeffect
operation entry. An interception update replaces the snapshot for later
operations. An operation already in progress keeps its entry snapshot.

Interception does not change provider availability, provider-episode identity,
or the committed provider view. It does not reactivate the consumer.

Coeffects without an interception descriptor cannot accept interception
metadata. Metadata values must be immutable. Each coeffect must provide
executable identity and associativity laws for its merge operation.

### Provider identity and admission

One provider episode has opaque, runtime-generated identity. The identity has
a one-to-one association with one component instance and generation. The pair
is diagnostic data and does not define equality.

Provider admission checks the prospective `(key, realm)` slot before mutation.
An occupied slot rejects the complete admission. The registry never contains
two discoverable providers for one slot.

Provider views and direct leases continue to follow
[Reactive resolution and withdrawal](13-reactive-resolution-and-withdrawal.md).
This decision does not replace its cancellation, settlement, or teardown
protocol.

### Realm reassignment

Realm reassignment is one coordinator transaction:

1. Compute every changed key and its old and new realms.
2. Select provider bindings controlled by the exact changed realm slot.
3. Validate every destination that will receive an owned provider binding.
4. Record the complete target view of each potentially affected consumer.
5. Commit the realm mappings and owned binding transfers together.
6. Recompute target views and queue only consumers whose target changed.

The effective realm slot, not ancestry alone, determines binding ownership. A
nearer realm override remains independent when an enclosing realm changes.

If a provider and consumer move together, the binding transfer preserves the
provider episode. The consumer does not reactivate because its complete target
view stays equal.

If only a consumer moves into an occupied realm, no provider binding moves. The
existing provider in that realm becomes the consumer target.

If only a provider moves, separated consumers lose that target. They settle
through the accepted withdrawal protocol before they wait or reactivate.

A destination conflict fails before commit. The current realm mappings,
provider index, provider views, and lifecycle state remain unchanged.

### Reactivation rules

- Deriving an unused context changes future resolution only.
- Changing interception changes later coeffect operations only.
- Incrementing a topology revision does not cause reactivation by itself.
- Reassigning a realm recomputes complete target views.
- An equal provider-episode view preserves the active generation.
- A changed or missing provider-episode view starts settlement.
- A complete new view activates a new consumer generation after settlement.

### Relationship to Cordis

This design preserves paper Definitions 27–31 and the observable result of
Algorithm 7. It uses typed OCaml values instead of JavaScript proxy properties.

Cordis uses traceable proxies to recover the caller context during service
invocation. Eta uses a typed wrapper with a runtime-owned snapshot. These
representations have the same operation-entry observation boundary.

The paper orders context metadata after component metadata. Eta keeps that
order without requiring one metadata algebra to model override priority. The
default TypeScript object merge remains an incidental behavior.

### Prototype evidence

The accepted prototype is on branch
`prototype/eta-component-isolation-interception` at commit `f6e0c0ad`. See the
[prototype source](https://github.com/ribelo/eta/tree/f6e0c0ad6c5c344356b85b06e2e6266b9b4a629b/.scratch/eta-component-runtime-isolation-interception).

The OxCaml gate compiled the typed context, requirement, provider index,
operation snapshots, and transfer transaction. Expected compiler failures
rejected incorrect context metadata, requirement metadata, and provider values.

Fixed traces covered paper-order metadata priority, an update during an
operation, separate providers for one key, shared realms, and nested overrides.

They also covered all movement classes, transfer rollback, duplicate admission,
and metadata monoid probes.
