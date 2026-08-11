# Structural model reset

Type: grilling
Status: resolved
Blocked by: 08

## Question

Does Eta Crux need one graph-owned operation that resets every stateful
computation in a structural subtree?

Compare explicit reset actions, keyed-incarnation replacement, and a structural
reset capability. Keep prior-value storage as application-owned state.

Decide whether to adopt, defer with a precise condition, or reject structural
reset. If adopted, specify the API shape, reset authority, traversal boundary,
active-child behavior, and keyed-child behavior. Also specify custom reset
functions, ordering, failure behavior, semantic laws, test controls, ownership,
and migration effects.

## Evidence

- [Bonsai structural model reset](../../../../.scratch/research/eta-crux-capability-audit/20-bonsai-structural-model-reset.md)

## Answer

### Decision

Adopt structural model reset as a graph-owned model transition. It resets one
explicit structural scope without replacing that scope.

The Bonsai evidence shows generic uses for multi-cell reset, local override
removal, memo-state clearing, and custom cleanup. The key evidence is semantic
ownership. Only Eta Crux can find state machines behind opaque computation
composition.

The three mechanisms keep separate roles:

| Mechanism | Decision | Role |
|---|---|---|
| Structural reset | Adopt | Reset all active state-machine descendants of one explicit scope. |
| Explicit reset actions | Retain | Reset one application-owned state machine or apply domain policy. |
| Keyed-incarnation replacement | Retain | End one keyed lifetime and create another lifetime with fresh identity. |

Prior-value storage remains application-owned state.

### Public API

Add this module to `eta_crux`:

```ocaml
module Reset : sig
  type 'a computation := 'a t
  type t

  val scope :
    'input computation ->
    f:
      (reset:t computation ->
       input:'input computation ->
       'output computation) ->
    'output computation

  val trigger :
    t ->
    (unit, Endpoint.admission_error) Eta.Effect.t
end
```

`Reset.scope input ~f` compiles `input` outside the reset scope. The `input`
argument to `f` is a read-only computation proxy inside the new scope.

The `reset` argument gives the same reset authority to computations inside the
scope. The builder decides whether its output exposes that authority.

Add this optional argument to `State_machine.create`:

```ocaml
?reset:
  (self:'action Endpoint.t ->
   input:'input ->
   model:'model ->
   'model * (unit, never) Eta.Effect.t option)
```

The default reset returns `default_model, None`. A custom reset can preserve the
model, compute another model, and stage one opaque typed-infallible effect.

The transition result also uses the optional effect shape accepted by
[Staged-effect observability](12-staged-effect-observability.md).

### Scope and authority

Each `Reset.scope` creates one fresh structural scope. The scope remains stable
while its enclosing structural occurrence remains active. Input and model
changes do not replace it.

One `Reset.t` remains stable for that active interval. Scope disposal makes the
authority stale. A later scope incarnation creates a fresh authority.

An outer reset reaches active state machines inside nested reset scopes. An
inner reset cannot reach state machines in its parent scope.

`Reset.t` is a local authority. It has no codec, remote handle, export node, or
driver administration operation. A serialized host uses an exported
application endpoint whose transition stages `Reset.trigger`.

### Admission and advancement

`Reset.trigger` waits for ordinary root-wide FIFO ingress admission. It returns
`Ingress_closed` when closure wins the admission race.

One successful trigger appends exactly one reset item. Admission does not run
the reset or promise later processing. Repeated triggers append separate items
and never coalesce.

Reset items keep FIFO order with endpoint actions. They do not use the control
path and receive no priority.

Scope validity is checked during advancement. A queued item for a disposed reset
scope is consumed and returns `Rejected Stale_reset` without a transition.
`Root.delivery_error` gains `Stale_reset`.

Each accepted reset of an active scope commits one complete root output. This
rule applies when every model remains equal and when the scope contains no state
machine.

### Traversal and snapshots

The traversal set contains every active state-machine descendant from the
committed frame before reset. It includes:

- state machines in static composition.
- state machines in the current `bind` branch.
- state machines for every current `Assoc` key.
- state machines inside active nested reset scopes.

Disposed children and children that do not exist in the committed frame are not
in the traversal set.

Each callback receives its own endpoint, input, and model from the same
pre-reset committed frame. A callback never observes another callback's reset
model.

Eta Crux publishes no callback traversal order. `Assoc` key order and structural
composition order do not define reset order.

### Commit, lifecycle, and keyed children

All reset models and graph changes stage in one advancement. Root output cannot
observe a partial reset.

Normal reconciliation applies to the reset models. Unchanged children preserve
their scopes, endpoints, sources, and active intervals.

A changed reset model can select another `bind` branch or change an `Assoc`
input. Removed children dispose through the normal lifecycle. New children start
with their default models and do not receive the reset that created them.

Continuous `Assoc` keys preserve their keyed incarnations. Their active
state-machine descendants receive reset callbacks. Structural reset does not
simulate key removal and re-entry.

Unchanged lifecycle programs do not restart. Unchanged source specifications
preserve their producer incarnations. Reset-driven structural or specification
changes use the existing lifecycle and source laws.

### Failure and staged effects

If a reset callback raises, the complete advancement rolls back. No reset model
or graph change commits, and no reset effect starts. The root records a
transition crash.

`Failure.trigger_kind` gains `Structural_reset`. The failure record contains the
failing cell and its model diagnostic. It contains no endpoint, action, or reset
identity.

Each present reset effect belongs to the structural scope of its state-machine
cell. The post-commit batch registers all effects behind closed gates before
removal cancellation.

After removal cancellation and source opening, eligible sibling reset effects
start concurrently. Eta Crux gives no start or settlement order between them.

An effect does not start if the reset commit disposes its owning cell. A later
effect defect cannot roll back the committed reset and follows the existing
owned-work failure rules.

### Staged-effect observation

A structural reset can stage zero or many transition effects. Therefore,
[Staged-effect observability](12-staged-effect-observability.md) changes its
`Staged` event to:

```ocaml
Staged of {
  position : Event_position.t;
  commit : Commit_index.t;
  effects : Effect_id.t list;
}
```

The list is the exact effect inventory for one commit. An ordinary endpoint
transition contributes zero or one item. A structural reset contributes one item
for each callback that returns `Some effect`.

List order introduces observer identities only. It has no structural, callback,
start, or settlement meaning.

### Test controls and executable laws

Eta Crux adds no reset-specific test bypass. Tests obtain a `Reset.t` from
application output or trigger it through application behavior. They use
`Reset.trigger`, normal frames, controlled dependencies, and the transition
effect observer.

The implementation effort adds these laws and named gates:

| Law | Gate |
|---|---|
| A generated nested graph resets exactly the active descendants of the selected reset scope. Generated graphs cover static composition, nested scopes, current `bind` branches, and current `Assoc` keys. The observation boundary is committed root output plus callback witnesses. | `qcheck_reset_scope_boundary` |
| Every reset callback observes the same pre-reset committed frame. One advancement publishes all reset models and graph changes or none. The generated class includes dependent models and equal outputs. | `qcheck_reset_snapshot_atomicity` |
| Default reset restores `default_model`. Custom reset can return default, preserved, or non-idempotent models. Generated repeated triggers run once each and never coalesce. | `qcheck_reset_default_custom` |
| Continuous keyed children preserve identity. Removed children dispose, and new children start with defaults. The generated class covers retained, removed, and added keys in one reset. | `qcheck_reset_dynamic_children` |
| Reset items and endpoint actions preserve accepted FIFO order. Every active no-change or empty reset still commits one complete output. | `qcheck_reset_ingress_order` |
| Reset-scope disposal and reset advancement have both legal winners. A reset winner commits before disposal. A disposal winner returns `Stale_reset` with no reset transition. | `race_reset_vs_disposal_both_winners` |
| A callback exception preserves the prior frame, starts no reset effect, and records `Structural_reset` with only the failing cell and model diagnostic. | `test_reset_callback_rollback` |
| Generated commits stage zero, one, and many reset effects. Exact observer inventory, owner disposal, concurrent sibling start, and every settlement class are covered. | `qcheck_reset_effect_lifecycle` |
| One authority stays stable across input and model changes. Disposal makes it stale, and re-entry creates a fresh authority. | `qcheck_reset_authority_incarnation` |
| A root with no reset scope performs no reset traversal and allocates no reset authority, item, or observation record during ordinary advancement. | `structural_reset_disabled_allocation` |

Generated failures print the graph, scope, callback models, ingress sequence, and
effect events. Cases with no valid background work finish with an empty fiber
census.

The disabled-path benchmark uses the existing disabled-telemetry threshold. It
requires equal per-action allocation and no more than a 5% median regression in
two of three comparisons.

### Ownership and cost

Eta Crux owns reset-scope identity, authority lifetime, traversal, FIFO
integration, atomic staging, reconciliation, and effect ownership.

Applications own scope placement, authority exposure, custom reset models,
custom reset effects, and external cleanup policy. Eta owns effect execution,
cancellation, scheduling, and finalizers.

Trigger work follows the active state-machine descendants of its reset scope.
Reset metadata follows those active descendants. A root with no `Reset.scope`
keeps the unused path inert.

### Migration

The production package adds `Reset`, the optional `State_machine.create` reset
callback, `Root.Stale_reset`, and `Failure.Structural_reset`.

The test package changes `Staged.effect` to `Staged.effects`. Observer consumers
must process zero, one, or many effect identities for each commit.

The optional reset callback requires no change for callers that use the default.
The separate staged-effect decision already requires all transition callbacks to
return `Some effect` or `None`.

Exhaustive matches on delivery errors, failure triggers, and observer events need
the new cases. The implementation effort updates public interfaces, semantic
laws, executable gates, verification text, and repository callers together.

There is no compatibility alias, fallback path, or silent conversion.
