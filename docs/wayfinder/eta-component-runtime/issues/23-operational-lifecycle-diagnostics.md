# Operational lifecycle diagnostics

Type: prototype
Status: resolved
Blocked by: 12, 13, 14, 15, 16, 17

## Question

Which immutable observation and diagnostics interface exposes component-context
health, instance phase, desired-state identity, provider episodes, settlement,
and retained causes?

Compare pull snapshots, event streams, and settlement reports. Define identity,
ordering, stale-observation, and cause-rendering rules. Separate application
observations from logs, metrics, and traces.

The interface must represent degraded contexts and quarantined instances. It
must not expose mutable instance handles or erase typed Eta causes.

## Prototype for review

The comparison prototype is on branch
`prototype/eta-component-operational-diagnostics` at commit `f5744913`. See the
[prototype source](https://github.com/ribelo/eta/tree/f574491301cb455b1481a41a1dd247c5c3665910/.scratch/eta-component-runtime-operational-diagnostics).

The corrected prototype compares an atomic snapshot, a typed bounded journal,
and operation settlement reports. It uses complete `Eta.Cause` values.

An independent high-tier review checked Cordis commit
`8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4` and the resolved Eta decisions. The
final verdict was `ready for human validation`.

The provisional recommendation selects snapshots, coalesced change waits,
context-owned settlement reports, and loader-owned pre-admission reports.

## Answer

Use immutable snapshots, coalesced change waits, and context-owned operation
fences. Use separate loader-operation reports for pre-admission work.

Do not expose a public lifecycle journal. Do not expose mutable component
instances, providers, supervisors, fibers, switches, or runtime tokens.

### Observation seam

One read-only diagnostics value belongs to one lexical component-context
lifetime. The public-interface decision can refine its module and operation
names.

The conceptual interface is:

```ocaml
module Diagnostics : sig
  type t
  type revision
  type snapshot

  type change =
    | Changed of snapshot
    | Closed of snapshot

  type await_error =
    | Wrong_context
    | Invalid_revision

  val snapshot : t -> (snapshot, never) Effect.t

  val await_change :
    t ->
    after:revision ->
    (change, await_error) Effect.t
end
```

The diagnostics value grants no reconciliation, retry, replacement, or
shutdown authority.

`snapshot` returns one atomic projection from the serialized context
coordinator. Reading diagnostics does not create a semantic lifecycle event.

`await_change` waits efficiently without creating a public event history. It
can coalesce intermediate revisions and returns the latest atomic snapshot.

### Snapshot contents

One snapshot contains:

- context identity and observation revision.
- the accepted desired revision.
- context lifecycle, progress, and integrity.
- desired-state entry and component-instance identities.
- each current component-instance phase.
- activation generation and provider-episode identities.
- committed provider views without provider values.
- opaque activation, recovery, and context failures.
- current operation-fence identities and states.

The snapshot does not contain component configuration, provision values,
coeffect values, interception metadata, or native module handles.

The snapshot is immutable through its public interface. It remains true for its
revision and can become stale immediately.

### Context health

Represent health with three independent facts.

Context lifecycle is:

- `Running`.
- `Stopping`.
- `Stopped`.

Context progress is:

- `Quiescent` when no accepted lifecycle work remains.
- `Reconciling` when an admitted operation can still make progress.
- `Blocked` when no legal lifecycle step can release an incomplete fence.

A missing provider can be quiescent. A clean activation failure can also be
quiescent after its generation settles.

A nonterminating operation remains `Reconciling`. Eta adds no default
diagnostic timeout.

Context integrity is:

- `Sound` when no instance is quarantined and no runtime invariant failed.
- `Degraded` with every quarantined component-instance identity.
- `Failed` with the complete context-invariant failure.

Only recovery failure quarantines an instance and degrades the context.
Activation failure does not degrade integrity.

Do not add one aggregate availability value. Instance phases, missing
requirements, and provider relationships expose those facts without
conflation.

### Identity rules

One context identity belongs to one lexical `Context.run` lifetime. A new
context lifetime creates a new identity.

An application-owned desired-state entry ID remains stable across movement,
disablement, reconfiguration, and declaration replacement.

One runtime-generated component-instance identity belongs to one entry
incarnation. Removal ends that identity. Re-adding the same entry ID creates a
new identity.

Every activation attempt gets a fresh generation identity. Generation identity
is monotonic within one component instance and is never reused.

Every committed provider activation gets a fresh opaque provider-episode
identity. Equal provision values do not preserve episode identity.

One settlement-fence identity belongs to one accepted context operation. One
loader-operation identity belongs to one submitted source revision.

Public identities support equality, comparison, and formatting. They do not
support parsing or lifecycle mutation.

### Revision and ordering rules

One serialized context coordinator assigns context-qualified observation
revisions.

Every mutation of a snapshot-visible fact advances the revision. Activation
start, activation completion, settlement start, and settlement completion use
distinct revisions.

One atomic coordinator transaction can change several facts under one revision.
For example, replacement publication exposes one complete staged batch.

A snapshot at revision `r` contains every visible mutation through `r`. It
contains no prefix of the transaction at `r`.

Revisions from different contexts are not comparable. A future same-context
revision is invalid.

Instance lists use desired-tree order. Retained settling instances follow
active desired entries in retirement order.

Provider episodes use opaque identity order. Requirement and provision
relationships use declaration order.

Eta cause children retain their existing left-to-right order. Diagnostics do
not infer causal order from observation revision order.

### Change-wait rules

For a live context, a stale same-context revision returns the latest snapshot
immediately.

For a live context, its current revision waits for a later snapshot.

Closure dominates every valid same-context revision. A closed context returns
`Closed final_snapshot` immediately.

A foreign revision returns `Wrong_context`. A future same-context revision
returns `Invalid_revision`.

Revision read and waiter registration form one atomic coordinator operation.
This rule prevents a missed change between the read and registration.

Several waiters can receive the same later snapshot. Cancellation stops only
the waiting effect and does not change component lifecycle.

### Context settlement

Each accepted reconciliation, explicit retry, replacement transaction, or
shutdown operation returns one immutable settlement fence.

Rollback and restoration remain phases and outcomes of one replacement fence.
They do not create separate public lifecycle authorities.

Repeated waits on one fence return the same terminal report. Different fences
can remain pending or complete at the same time.

One terminal settlement report contains:

- fence identity and operation kind.
- admission and terminal coordinator revisions.
- its final atomic snapshot.
- its terminal outcome.
- every operation participant.
- every operation-local retained failure.

One participant record contains:

- desired-state entry identity.
- component-instance identity.
- participating activation generations.
- participating provider episodes.
- terminal phase or removal outcome.
- its failure, when one exists.

A participant remains in the report after it leaves current state. Thus, the
report replaces the diagnostic function of a caller-held Cordis `Fiber`.

The operation outcome is one of:

- `Quiescent`.
- `Superseded`.
- `Rolled_back`.
- `Degraded`.
- `Restoration_failed`.
- `Context_failed`.

A rejected admission returns its typed admission error and creates no
settlement fence.

A nonterminating operation produces no false terminal report. A blocked
shutdown remains pending.

### Retained failures and rendering

Production diagnostics expose an opaque `Failure.t`.

The implementation retains the original existential same-domain
`'error Cause.t`. It never converts the authoritative failure to `result`,
rendered text, or a log-only event.

When the cause settles, diagnostics render each typed failure leaf once. They
then derive stable pretty, compact, and portable projections from that rendered
cause.

`Failure.pp` and `Failure.pp_compact` use captured text. They do not invoke
component code or a retained error printer.

If rendering raises, diagnostics retain the original cause and expose an
explicit `Renderer_failed` diagnostic. The rendering failure does not replace,
suppress, or augment the lifecycle cause.

The production interface does not unpack the existential cause. This rule
prevents callers from observing mutable application error payloads.

[Executable laws and reference model](20-executable-laws-and-reference-model.md)
can define a trusted test-only interface for exact cause inspection.

### Loader and native-replacement reports

The loader or native-HMR adapter owns source work before component-context
admission.

Submitting one source revision returns one immutable loader operation. Waiting
on that operation returns the same immutable report to every waiter.

The loader report contains:

- source and build revision.
- preparation and native-load outcome.
- stale-candidate rejection.
- linked replacement-fence identity, when admission occurred.
- native artifact residency.

Native artifact residency is `Retained`, `Unreachable_but_loaded`, or
`Unknown`.

A preparation or load rejection does not advance the core diagnostics revision
because component-context state did not change.

Accepted replacement, rollback, restoration, quarantine, and publication facts
remain in the context-owned replacement report.

### Telemetry separation

Snapshots and settlement reports are authoritative application observations.
Telemetry is not authoritative.

Built-in logs, metrics, and traces contain fixed operation categories, outcome
categories, and durations. They do not contain configuration, provider values,
coeffect values, typed error values, or rendered application causes.

Built-in metrics use bounded labels and contain no entry, instance, generation,
episode, or fence identity.

Applications can consume diagnostics and emit their own redacted audit records.
The component runtime does not do this automatically.

Telemetry loss, buffering, reordering, or sampling cannot change lifecycle
results, revisions, snapshots, or settlement reports.

Disabled telemetry changes no result, ordering, scheduling, cancellation,
identity, failure, or settlement.

### Cordis relationship

Cordis exposes public mutable `Fiber` values and synchronous
`internal/status`, `internal/plugin`, and `internal/service` events.

Eta retains the observable phase and disposal facts through snapshots and
participant reports. It does not transfer the mutable handles or synchronous
observer coupling.

Cordis observers can see every delivered status event. Eta change waits can
coalesce revisions. This is an intentional rejection of a public lifecycle
history.

Cordis rethrows one stored activation error from `Fiber.await`. Eta retains the
complete cause privately and exposes stable opaque diagnostics.

Cordis logs and swallows disposer failures. Eta quarantines the failed instance,
retains its complete finalizer cause, and degrades the component context.

### Prototype evidence

The accepted prototype is on branch
`prototype/eta-component-operational-diagnostics` at commit `f5744913`. See the
[prototype source](https://github.com/ribelo/eta/tree/f574491301cb455b1481a41a1dd247c5c3665910/.scratch/eta-component-runtime-operational-diagnostics).

The Nix and OxCaml gate compiled the model and ran every fixed trace. The traces
covered separate lifecycle revisions, removed participants, concurrent fences,
recovery failure, closed waits, missing providers, native load rejection,
rollback, and restoration failure.

An independent high-tier review compared the prototype with Cordis commit
`8cc9e33fab69e2d0476d126baaf2acb24e6a6ab4`. After four review rounds, its final
verdict was `ready for human validation`. The user approved every recommended
choice.
