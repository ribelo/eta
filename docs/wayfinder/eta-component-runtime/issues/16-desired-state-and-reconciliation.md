# Desired state and reconciliation

Type: prototype
Status: resolved
Blocked by: 02, 12, 13, 14

## Question

What typed desired-state tree and reconciliation algorithm can create, remove,
move, disable, reconfigure, isolate, and intercept component instances?

Prototype stable entry identity, keyed child reconciliation, nested groups, and
concurrent module preparation. Define the authority split between an entry, a
component instance, and application-owned configuration.

The answer must make final quiescent state depend on final desired state, not
on reconciliation order.

## Answer

Use one immutable, typed desired-state tree and whole-snapshot reconciliation.
The application owns the tree. One serialized component-context coordinator
owns its interpretation.

### Desired-state tree

Every group and component entry has one application-owned, stable ID. IDs are
unique in the complete tree. Child position is structural data, not identity.

An ID cannot change between a group and an entry while its old runtime
authority exists. The application must remove and settle the old authority
before it reuses the ID with another node kind.

A group is a structural context node. It carries inherited enablement,
isolation, and interception values. It does not create a component instance.
The runtime retains one private context slot for each installed group ID.

If a group leaves desired state, its context slot remains while a descendant
settles. The runtime removes the slot after the last descendant leaves.

One typed entry constructor pairs a component with its configuration before it
hides that pair:

```ocaml
type entry =
  | Entry : {
      id : Entry_id.t;
      component : 'config Component.t;
      config : 'config;
      enabled : bool;
      context : Context_spec.t;
    } -> entry
```

This shape adds one configuration parameter to the provisional component
representation. Requirement, provision, and error types remain existential as
selected in [Typed key and coeffect contract](10-typed-key-and-coeffect-contract.md).
The public-interface decision can refine names and constructor layout.

Each component defines typed configuration equivalence. Equivalent
configuration preserves the current activation target. Non-equivalent
configuration starts a fresh serialized activation generation.

Each retained entry also has one opaque accepted target revision. It covers
the entry incarnation, enablement, declaration, configuration equivalence
class, and complete effective context. Reordering does not change this
revision.

### Authority split

The application owns:

- stable IDs and child order.
- the complete immutable hierarchy.
- enablement and typed configuration.
- isolation and interception assignments.

A desired-state entry is a correlation identity. It does not own a live
component, mutable configuration, or lifecycle transition.

A loader adapter owns module resolution, serialization, interpolation, and
source-specific diagnostics. It prepares a typed candidate tree but cannot
mutate the component context.

The component runtime owns:

- group context slots and component instances.
- activation generations and provider episodes.
- committed provider views and direct leases.
- admission, settlement, cleanup, and lifecycle diagnostics.

### Preparation and admission

Module preparation can run concurrently. Each preparation token contains its
source revision. A stale completion cannot complete work for a newer source
revision.

All preparation tasks must finish before candidate admission. A preparation
failure or candidate-construction exception rejects that source revision. The
accepted desired state and component context remain unchanged.

Admission flattens the complete candidate and validates these conditions before
lifecycle mutation:

- All node IDs are unique.
- A retained ID does not change node kind.
- Each effectively enabled prospective `(coeffect key, realm)` slot has at
  most one provider declaration.
- The prospective provider graph is acyclic.

A missing provider is valid. The affected consumer remains waiting.

Configuration-equivalence and interception-merge callbacks run before
lifecycle mutation. A callback exception rejects admission with a typed
callback-defect error. The accepted state remains unchanged.

The coordinator accepts one validated candidate as one desired revision. A
newer source revision replaces an incomplete older revision. Preparation order
does not define lifecycle order.

### Reconciliation protocol

The coordinator derives every effective group and entry value from the final
tree before it starts per-entry lifecycle work.

It preserves private group context slots and component instances by stable ID.
A move updates structural parentage but does not create a new instance.

Admission fences every active or activating provider whose final target must
retire. Retirement includes removal, disablement, non-equivalent
configuration, and a changed complete provider view.

The coordinator computes this fence to a fixed point. If an upstream provider
retires, each provider that retains its episode also retires before ordinary
consumer reconciliation starts. New resolution cannot observe a fenced
episode.

Realm reassignment and provider retirement form one serialized admission
operation. An uncontested realm transfer can commit during structural
installation. If a destination is blocked, the coordinator fences departing
providers and then retries the complete realm transaction.

After admission, each component-instance coordinator reads only the latest
accepted snapshot. It does not apply an incremental tree patch.

A later accepted operation supersedes an unfinished conflicting target. The
older fence waits for work that it started. Clean settlement reports
`Superseded`; recovery failure reports `Degraded`. Disjoint operations can
settle independently.

The coordinator applies these entry rules:

- Creation allocates one component instance for the stable entry ID.
- Reordering changes position only.
- Moving preserves component-instance identity.
- Disablement settles the active generation and retains an inactive instance.
- Re-enablement starts a fresh generation on that retained instance.
- Removal settles the instance and then removes its identity.
- Re-adding a removed ID allocates a new component instance.
- Non-equivalent configuration settles before a fresh generation starts.
- An isolation change recomputes the complete provider view.
- An equal provider-episode view preserves the active generation.
- A changed or missing provider view starts settlement.
- An interception change updates later operation snapshots without
  reactivation.

If one provider episode satisfies several required keys, the consumer retains
one dependency edge and one direct lease for that episode.

Settlement follows
[Reactive resolution and withdrawal](13-reactive-resolution-and-withdrawal.md).
A retiring episode remains available only through committed old views.
Cleanup cannot finish while a direct consumer retains its lease.

### Convergence and quiescence

Quiescence means that no preparation, reconciliation, activation, or
settlement work remains.

For one initial committed state and one final valid desired snapshot, the
quiescent projection is independent of preparation and reconciliation order
under these conditions:

- The desired provider graph is finite and acyclic.
- The source revision stops changing while reconciliation settles.
- Activation and cleanup operations terminate.
- Cleanup succeeds.
- Component outcomes are fixed for the compared executions.

The projection contains desired structure, effective context, lifecycle phase,
typed configuration, and provider relationships. It alpha-normalizes opaque
runtime identities and excludes diagnostic counters.

Failure and nontermination retain the outcomes from
[Component lifecycle and failure](12-component-lifecycle-and-failure.md).
They do not permit a false successful-quiescence claim.

### Cordis relationship

Eta retains Cordis stable entry matching, keyed child reconciliation, inherited
disablement, realm movement, interception inheritance, and inertial
replacement.

Eta strengthens Cordis in three places:

- Admission validates one complete typed snapshot before lifecycle mutation.
- Provider retirement reaches a fixed point before per-entry reconciliation.
- Complete Eta causes and failed-cleanup leases remain observable.

The global retirement fence preserves the Cordis simultaneous-update
regression rule. A provider and consumer that both change can observe only the
old provider with old configuration or the new provider with new
configuration. They cannot activate with a mixed pair.

Eta does not copy Cordis random IDs, dynamic configuration, group-plugin
instances, JavaScript object merging, or incremental `Promise.all` mutation.

### Prototype evidence

The accepted prototype is on branch
`prototype/eta-component-desired-state` at commit `0094f27e`. See the
[prototype source](https://github.com/ribelo/eta/tree/0094f27e7a93d0070794e407f918b1b22115d7a0/.scratch/eta-component-runtime-desired-state).

The OxCaml gate rejected an incorrect configuration type. Fixed traces covered
creation, removal, keyed movement, nested disablement, reconfiguration,
isolation, interception, realm conflicts, stale preparation, and source
failure.

The traces also covered simultaneous provider and consumer changes and two
required keys from one provider episode. They covered both node-kind changes,
opposite lifecycle orders, and removal during settlement.
