# Module replacement and rollback

Type: prototype
Status: resolved
Blocked by: 02, 07, 12, 16

## Question

What HMR contract can replace affected component declarations transactionally
on native Eta?

Prototype dependency classification, stale-entry detection, component
replacement, load failure, and restoration of the previous declarations.
Separate code loading from component replacement.

Preserve serialized generations within one component instance. Decide whether a
replacement transaction uses a distinct candidate instance that can become
discoverable while the old provider episode drains.

Component-local state does not migrate. The answer must state what remains
loaded after rollback and what machine-code or module artifacts native OCaml
cannot unload.

## Answer

Use one replacement transaction for one prepared source revision. Keep native
code loading separate from declaration replacement.

### Classification and loading

The native adapter reads an authoritative build manifest after each dirty
signal. File-watch event order does not define source truth.

The adapter classifies changes as follows:

- A private module change rebuilds each declaration whose dependency closure
  contains that module.
- A stable host-interface or runtime change requires a process restart.
- An unknown dependency rejects the source revision.

Each candidate has an immutable artifact path, a unique compilation unit, and a
source revision. It also records the component identity and build identity from
the native-HMR decision.

The adapter loads every candidate privately before it changes the component
context. Each plugin initializer can register exactly one inactive candidate
declaration through the stable host interface.

A load failure rejects the complete source revision. The accepted desired state
and all component instances remain unchanged.

Module initializers must not perform component effects. Eta cannot enforce this
rule against trusted native code.

### Stale candidate detection

Preparation records the source revision, each affected entry incarnation, and
each accepted target revision. A target revision covers enablement,
declaration, configuration equivalence, and effective context. Admission
rejects the complete batch if any stamp is stale.

One source authority assigns strictly increasing source revisions. Equal or
decreasing revisions fail before preparation or core admission.

A rejected batch is terminal. A retry requires a fresh source revision and new
candidate authority.

The adapter also checks the candidate component identity and module locator.
These checks occur before lifecycle mutation.

The stable component family owns the authorized module locator. A native load
token binds that locator to one target, artifact, and unique compilation unit.

### Instance and generation identity

A retained desired-state entry keeps one Eta component instance and one private
lifecycle coordinator. Replacement does not allocate a distinct candidate
component instance.

Each candidate activation uses a fresh serialized generation and a fresh Eta
scope. Restoration uses another fresh generation in the same component
instance.

Cordis creates a fresh `Fiber` and associates it with the stable loader entry.
For Eta, that fresh fiber corresponds to an activation generation, not a
component instance.

This decision refines the “fresh instance” wording in
[Native loading and HMR](07-native-loading-and-hmr.md). The native loading and
code-retention conclusions remain unchanged.

A removed and later re-added entry creates a new entry incarnation and a new
component instance.

### Replacement transaction

Immediately before lifecycle mutation, the transaction retains the current
declarations and committed configuration snapshots. It then fences each
provider in the affected runtime closure.

Old generations settle in consumer-first order. A fenced old provider remains
available only through committed old consumer leases during drainage.

Candidate activations start in provider-first order. Start and completion are
separate lifecycle steps.

Completed candidates enter a transaction-local staged view. A staged consumer
can resolve a staged provider from the same transaction.

Other component instances cannot discover staged providers. The coordinator
publishes all staged provider episodes in one commit.

This atomic publication is an Eta strengthening. Cordis replaces stale entries
sequentially and has no transaction-local provider namespace.

Eta does not promise zero-gap replacement. The global provider slot can remain
empty between old settlement and candidate publication.

If a required provider is unavailable, the new declaration can commit without
an activation. The consumer remains waiting and has no provider view.

### Failure and rollback

Keep these outcomes distinct:

- Native load failure occurs before component lifecycle mutation.
- Synchronous candidate installation failure starts rollback.
- Asynchronous candidate activation failure also starts rollback.
- Candidate cleanup failure quarantines the instance and prevents restoration
  in that component context.
- Restoration activation failure publishes no restored provider set.
- Restoration cleanup failure quarantines the instance and degrades the
  component context.

Rollback after asynchronous activation failure is an Eta strengthening. Cordis
removes the old fiber and records the new fiber failure without HMR rollback.

Clean rollback closes every candidate attempt. It then activates the
declarations and configurations captured immediately before lifecycle
mutation. It does not restore a preparation-time target.

Restoration stages all successful old generations before one coordinator
commit. A failed restoration closes every staged restoration attempt and
publishes none of them.

A later transaction cannot include a quarantined instance in its participant
closure. A degraded context can continue to coordinate unrelated instances.

All activation, cleanup, and restoration failures retain complete Eta causes
under [Component lifecycle and failure](12-component-lifecycle-and-failure.md).

### State and native retention

Restoration does not recover component-local state. State survives only when a
longer-lived context or coeffect owns it.

The old declaration values remain retained during the transaction. Candidate
declaration values can become unreachable after rejection or rollback.

Unreachable declarations do not unload native code. Candidate machine code,
module globals, frame tables, GC roots, and code-fragment metadata can remain
loaded.

A failed native load can also leave partial code resident. Diagnostics report
unknown residency when the native loader cannot determine it.

Only a process restart reclaims all native generations.

### Prototype evidence

The accepted prototype is on branch
`prototype/eta-component-module-replacement` at commit `7bf6d795`. See the
[prototype source](https://github.com/ribelo/eta/tree/7bf6d7954a0bb63bfdf75292ac20140975e15b53/.scratch/eta-component-runtime-module-replacement).

The OxCaml build and scripted traces covered successful replacement, stale
incarnations, load failure, installation failure, activation failure, cleanup
failure, restoration failure, and source supersession.

The traces also covered quarantine admission, unavailable providers,
transaction-local visibility, exact publication counts, second-generation
rollback, and native artifact status.

An independent review compared the model with the Cordis implementation and
tests. Its final verdict was `ready for human validation`, and the user approved
the corrected contract.
