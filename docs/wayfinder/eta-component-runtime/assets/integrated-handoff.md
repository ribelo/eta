# Integrated Eta component runtime handoff

Status: approved

This handoff belongs to
[Integrated design and handoff](../issues/22-integrated-design-and-handoff.md).
It integrates the resolved decisions into one implementation contract.

## Contract precedence

This handoff resolves differences between earlier prototype decisions. The
following refinements are final:

- `Effect.t` keeps its two existing type parameters.
- Desired-state reconciliation is the only component-instance creation
  authority.
- A provider episode has one opaque identity. It has a one-to-one association
  with one component instance and one activation generation.
- Interception metadata forms a monoid. The runtime folds component metadata,
  outer-context metadata, and inner-context metadata in that order.
- `Activation.own` reports closed admission as requested lifecycle
  interruption.
- `Activation.own` requires a release-error renderer.
- `Component.make` rejects duplicate and self-dependent schema keys.
- Replacement candidates carry an accepted target revision.
- A later accepted target supersedes an earlier conflicting target.
- Repeated shutdown returns the first shutdown fence.

The implementation can change private names and data structures. It cannot
change these observable rules without a new design decision and new laws.

## Public package interfaces

The interfaces below are design signatures. Production documentation must add
the named executable laws in the same change as each normative interface span.

### `eta_component`

`eta_component` exposes the `Eta_component` façade. The façade contains these
modules:

```ocaml
module Coeffect : sig
  type 'value contract
  type 'value t = 'value contract

  val create :
    name:string ->
    equivalent:('value -> 'value -> bool) ->
    unit ->
    'value t

  val name : _ t -> string

  module Interception : sig
    type ('value, 'metadata) t

    val create :
      name:string ->
      equivalent:('value -> 'value -> bool) ->
      empty:'metadata ->
      merge:('metadata -> 'metadata -> 'metadata) ->
      wrap:(sample:(unit -> 'metadata) -> 'value -> 'value) ->
      unit ->
      ('value, 'metadata) t

    val coeffect :
      ('value, 'metadata) t ->
      'value contract
  end
end

module Requirement : sig
  type 'input t

  val none : unit t
  val one : 'value Coeffect.t -> 'value t

  val intercepted :
    ('value, 'metadata) Coeffect.Interception.t ->
    metadata:'metadata ->
    'value t

  val both : 'left t -> 'right t -> ('left * 'right) t
  val map : ('input -> 'output) -> 'input t -> 'output t
end

module Provision : sig
  type 'output t

  val none : unit t
  val one : 'value Coeffect.t -> 'value t
  val both : 'left t -> 'right t -> ('left * 'right) t
  val contramap : ('output -> 'staged) -> 'staged t -> 'output t
end

module Activation : sig
  type t

  val own :
    t ->
    acquire:('resource, 'acquire_error) Eta.Effect.t ->
    release:('resource -> (unit, 'release_error) Eta.Effect.t) ->
    pp_release_error:(Format.formatter -> 'release_error -> unit) ->
    ('resource, 'acquire_error) Eta.Effect.t
end

module Component : sig
  module Family : sig
    type 'config t

    val create :
      name:string ->
      module_locator:string ->
      unit ->
      'config t

    val name : _ t -> string
    val module_locator : _ t -> string
  end

  type declaration_error =
    | Duplicate_requirement of string
    | Duplicate_provision of string
    | Self_dependency of string

  type 'config t
  type packed

  val make :
    family:'config Family.t ->
    config_equal:('config -> 'config -> bool) ->
    requirements:'requirements Requirement.t ->
    provisions:'provisions Provision.t ->
    pp_error:(Format.formatter -> 'error -> unit) ->
    activate:
      ('config ->
       'requirements ->
       Activation.t ->
       ('provisions, 'error) Eta.Effect.t) ->
    ('config t, declaration_error) result

  val family : 'config t -> 'config Family.t
  val pack : 'config t -> packed
end

module Entry_id : sig
  type t

  val of_string : string -> (t, [ `Invalid_entry_id ]) result
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Desired_state : sig
  module Realm : sig
    type t

    val create : name:string -> unit -> t
    val name : t -> string
  end

  module Context_spec : sig
    type t

    val empty : t
    val isolate : 'value Coeffect.t -> Realm.t -> t -> t

    val intercept :
      ('value, 'metadata) Coeffect.Interception.t ->
      'metadata ->
      t ->
      t
  end

  module Entry : sig
    type 'config t

    val make :
      id:Entry_id.t ->
      component:'config Component.t ->
      config:'config ->
      enabled:bool ->
      context:Context_spec.t ->
      'config t

    val id : _ t -> Entry_id.t
  end

  type node
  type t

  val component : _ Entry.t -> node

  val group :
    id:Entry_id.t ->
    enabled:bool ->
    context:Context_spec.t ->
    node list ->
    node

  val tree : node list -> t
end

module Source_revision : sig
  type t

  val of_int64 : int64 -> t
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Diagnostics : sig
  module Context_id : sig
    type t

    val equal : t -> t -> bool
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
  end

  module Desired_revision : sig
    type t

    val equal : t -> t -> bool
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
  end

  module Target_revision : sig
    type t

    val equal : t -> t -> bool
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
  end

  module Instance_id : sig
    type t

    val equal : t -> t -> bool
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
  end

  module Generation_id : sig
    type t

    val equal : t -> t -> bool
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
  end

  module Episode_id : sig
    type t

    val equal : t -> t -> bool
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
  end

  module Fence_id : sig
    type t

    val equal : t -> t -> bool
    val compare : t -> t -> int
    val pp : Format.formatter -> t -> unit
  end

  module Failure : sig
    type t
    type renderer_failure

    type rendering = {
      pretty : string;
      compact : string;
      portable : string Eta.Cause.Portable.t;
    }

    type render_result =
      | Rendered of rendering
      | Renderer_failed of renderer_failure

    val rendering : t -> render_result
    val pp : Format.formatter -> t -> unit
    val pp_compact : Format.formatter -> t -> unit
    val pp_renderer_failure :
      Format.formatter ->
      renderer_failure ->
      unit
  end

  type lifecycle = Running | Stopping | Stopped
  type progress = Quiescent | Reconciling | Blocked

  type integrity =
    | Sound
    | Degraded of Instance_id.t list
    | Failed of Failure.t

  type phase =
    | Inactive
    | Waiting
    | Activating of Generation_id.t
    | Active of Generation_id.t
    | Settling of Generation_id.t
    | Activation_failed of Generation_id.t * Failure.t
    | Recovery_failed of Generation_id.t * Failure.t

  type revision
  type requirement_binding
  type instance
  type snapshot
  type t

  val context_id : snapshot -> Context_id.t
  val revision : snapshot -> revision
  val accepted_desired_revision : snapshot -> Desired_revision.t option
  val lifecycle : snapshot -> lifecycle
  val progress : snapshot -> progress
  val integrity : snapshot -> integrity
  val instances : snapshot -> instance list

  val entry_id : instance -> Entry_id.t
  val instance_id : instance -> Instance_id.t
  val target_revision : instance -> Target_revision.t option
  val phase : instance -> phase
  val provider_episode : instance -> Episode_id.t option
  val committed_view : instance -> requirement_binding list

  val requirement_name : requirement_binding -> string
  val requirement_provider : requirement_binding -> Episode_id.t

  type change =
    | Changed of snapshot
    | Closed of snapshot

  type await_error =
    | Wrong_context
    | Invalid_revision

  val snapshot : t -> (snapshot, 'error) Eta.Effect.t

  val await_change :
    t ->
    after:revision ->
    (change, await_error) Eta.Effect.t

  module Fence : sig
    type t
    type participant
    type report

    type kind =
      | Reconcile of Desired_revision.t
      | Retry of Entry_id.t
      | Replace of Source_revision.t
      | Shutdown

    type outcome =
      | Quiescent
      | Superseded
      | Rolled_back
      | Degraded
      | Restoration_failed
      | Context_failed

    type participant_role =
      | Started
      | Retired
      | Restored
      | Waited

    val id : t -> Fence_id.t
    val await : t -> (report, 'error) Eta.Effect.t

    val report_id : report -> Fence_id.t
    val kind : report -> kind
    val admitted_at : report -> revision
    val completed_at : report -> revision
    val outcome : report -> outcome
    val final_snapshot : report -> snapshot
    val participants : report -> participant list
    val failures : report -> Failure.t list

    val participant_entry : participant -> Entry_id.t
    val participant_instance : participant -> Instance_id.t
    val participant_roles : participant -> participant_role list
    val participant_generations :
      participant ->
      Generation_id.t list
    val participant_episodes : participant -> Episode_id.t list
    val participant_terminal_phase : participant -> phase option
    val participant_removed : participant -> bool
    val participant_failure : participant -> Failure.t option
  end

  type fence_observation

  val fences : snapshot -> fence_observation list
  val observed_fence_id : fence_observation -> Fence_id.t
  val observed_fence_kind : fence_observation -> Fence.kind
  val observed_fence_complete : fence_observation -> bool
end

module Replacement : sig
  type 'config target
  type packed_target
  type candidate
  type batch

  type candidate_error =
    | Component_identity_mismatch of Entry_id.t

  type batch_error =
    | Empty_batch
    | Duplicate_entry of Entry_id.t

  val target :
    entry:'config Desired_state.Entry.t ->
    expected_instance:Diagnostics.Instance_id.t ->
    expected_target:Diagnostics.Target_revision.t ->
    'config target

  val pack_target : 'config target -> packed_target

  val candidate :
    target:'config target ->
    component:'config Component.t ->
    (candidate, candidate_error) result

  val loaded_candidate :
    target:packed_target ->
    component:Component.packed ->
    (candidate, candidate_error) result

  val batch :
    source_revision:Source_revision.t ->
    candidate list ->
    (batch, batch_error) result
end

module Context : sig
  type t

  type callback =
    | Configuration_equivalence
    | Interception_merge of string

  type admission_error =
    | Context_not_running
    | Duplicate_entry_id of Entry_id.t
    | Entry_kind_changed of Entry_id.t
    | Duplicate_provider of {
        coeffect : string;
        realm : string;
        entries : Entry_id.t list;
      }
    | Dependency_cycle of Entry_id.t list
    | Callback_failed of {
        callback : callback;
        failure : Diagnostics.Failure.t;
      }
    | Retry_not_available of Entry_id.t
    | Stale_source_revision of Source_revision.t
    | Stale_entry_incarnation of Entry_id.t
    | Stale_target_revision of Entry_id.t
    | Wrong_target_context of Entry_id.t
    | Component_identity_mismatch of Entry_id.t
    | Quarantined_instance of Entry_id.t

  val run :
    (t -> Diagnostics.t -> ('value, 'error) Eta.Effect.t) ->
    ('value, 'error) Eta.Effect.t

  val reconcile :
    t ->
    Desired_state.t ->
    (Diagnostics.Fence.t, admission_error) Eta.Effect.t

  val retry :
    t ->
    Entry_id.t ->
    (Diagnostics.Fence.t, admission_error) Eta.Effect.t

  val replace :
    t ->
    Replacement.batch ->
    (Diagnostics.Fence.t, admission_error) Eta.Effect.t

  val shutdown :
    t ->
    (Diagnostics.Fence.t, admission_error) Eta.Effect.t
end
```

`Coeffect.create` creates a noninterceptable coeffect.
`Coeffect.Interception.create` creates one interceptable coeffect and its only
typed interception descriptor.

The `equivalent`, `config_equal`, `merge`, `wrap`, `map`, `contramap`, and
renderer callbacks must be total. The runtime still classifies a callback
exception according to the callback boundary below.

`Component.make` checks schema keys without running user callbacks. It returns
the first declaration error in declaration order. A key cannot occur twice in
one schema. One component cannot require and provide the same key.

`Context.run` owns the complete lexical component-context lifetime. Body exit,
failure, or interruption starts shutdown and waits for owned settlement.
Cleanup failure uses Eta finalizer and suppression rules.

Explicit shutdown can stop the context before the body returns. A repeated
shutdown call returns the existing shutdown fence. Later non-shutdown
operations return `Context_not_running`.

### `eta_component_loader`

`eta_component_loader` exposes the `Eta_component_loader` façade:

```ocaml
type never = |

type prepared =
  | Desired_state of Eta_component.Desired_state.t
  | Replacement of Eta_component.Replacement.batch

module Operation_id : sig
  type t

  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

module Failure : sig
  type t

  val pp : Format.formatter -> t -> unit
end

type residency =
  | Retained
  | Unreachable_but_loaded
  | Unknown

type artifact = {
  locator : string;
  residency : residency;
}

type rejection_stage =
  | Preparation
  | Native_load

type 'error preparation =
  | Ready of {
      source_revision : Eta_component.Source_revision.t;
      build_revision : string option;
      prepared : prepared;
      artifacts : artifact list;
    }
  | Rejected of {
      source_revision : Eta_component.Source_revision.t;
      build_revision : string option;
      stage : rejection_stage;
      error : 'error;
      artifacts : artifact list;
    }
  | Needs_restart of {
      source_revision : Eta_component.Source_revision.t;
      build_revision : string option;
      artifacts : artifact list;
    }

module type ADAPTER = sig
  type source
  type error

  val revision : source -> Eta_component.Source_revision.t
  val prepare : source -> (error preparation, never) Eta.Effect.t
  val pp_error : Format.formatter -> error -> unit
end

module Make (Adapter : ADAPTER) : sig
  type t
  type operation
  type report

  type submit_error =
    | Loader_not_running
    | Source_revision_not_newer of {
        latest : Eta_component.Source_revision.t;
        submitted : Eta_component.Source_revision.t;
      }

  type outcome =
    | Preparation_rejected of Failure.t
    | Native_load_rejected of Failure.t
    | Stale_candidate
    | Restart_required
    | Admission_rejected of Eta_component.Context.admission_error
    | Admitted of Eta_component.Diagnostics.Fence.t
    | Loader_stopped

  val run :
    Eta_component.Context.t ->
    (t -> ('value, 'error) Eta.Effect.t) ->
    ('value, 'error) Eta.Effect.t

  val submit :
    t ->
    Adapter.source ->
    (operation, submit_error) Eta.Effect.t

  val await : operation -> (report, 'error) Eta.Effect.t

  val operation_id : report -> Operation_id.t
  val source_revision :
    report ->
    Eta_component.Source_revision.t
  val build_revision : report -> string option
  val outcome : report -> outcome
  val artifacts : report -> artifact list
end
```

The adapter receives no component-context authority. The loader coordinator
owns the authority that links a prepared value to context admission.

`Make.run` owns one lexical loader lifetime. Body exit closes submission,
cancels incomplete preparation, records `Loader_stopped`, and waits for loader
work to settle.

Each accepted source revision creates one loader operation. Repeated waits
return the same report. A later accepted submission supersedes incomplete
preparation for an earlier revision. Revision comparison does not define
completion order.

Source revisions form one strictly increasing sequence for each loader. The
loader rejects a submitted revision that is not greater than its latest
accepted revision.

### `eta_component_loader_native`

`eta_component_loader_native` exposes the
`Eta_component_loader_native` façade:

```ocaml
module Host : sig
  type t

  val make :
    compiler:string ->
    target:string ->
    plugin_magic:string ->
    stable_interface_digest:string ->
    allowed_units:string list ->
    generation_directory:string ->
    t
end

module Dependency : sig
  type kind =
    | Private_module
    | Stable_host_interface
    | Runtime_module
    | Unknown_dependency

  type t

  val make :
    unit_name:string ->
    kind:kind ->
    requires:string list ->
    t
end

module Artifact : sig
  type t

  val make :
    target:Eta_component.Replacement.packed_target ->
    build_path:string ->
    module_locator:string ->
    compilation_unit:string ->
    digest:string ->
    t
end

module Manifest : sig
  type t

  type error =
    | Duplicate_unit of string
    | Missing_dependency of string
    | Duplicate_target of Eta_component.Entry_id.t

  val make :
    source_revision:Eta_component.Source_revision.t ->
    build_revision:string ->
    changed_units:string list ->
    dependencies:Dependency.t list ->
    artifacts:Artifact.t list ->
    (t, error) result
end

module Plugin : sig
  type registration_error =
    | Registration_outside_load
    | Duplicate_registration
    | Unauthorized_family

  val register :
    'config Eta_component.Component.t ->
    (unit, registration_error) result
end

module type SOURCE = sig
  type dirty
  type error

  val host : Host.t
  val revision : dirty -> Eta_component.Source_revision.t

  val read_manifest :
    dirty ->
    (Manifest.t, error) Eta.Effect.t

  val pp_error : Format.formatter -> error -> unit
end

module Make (Source : SOURCE) : sig
  type source = Source.dirty

  type error =
    | Source_error of Source.error
    | Manifest_error of Manifest.error
    | Unknown_dependency of string
    | Host_mismatch of string
    | Native_load_failed of {
        artifact : string;
        message : string;
      }
    | Registration_failed of Plugin.registration_error
    | Missing_registration of string
    | Candidate_mismatch of Eta_component.Entry_id.t

  val revision : source -> Eta_component.Source_revision.t
  val prepare :
    source ->
    (error Eta_component_loader.preparation,
     Eta_component_loader.never)
      Eta.Effect.t
  val pp_error : Format.formatter -> error -> unit
end
```

The native adapter treats a dirty value only as a rescan request.
`read_manifest` returns the authoritative build state.

The adapter classifies the complete dependency closure. A private-module
change rebuilds each affected declaration. A stable-interface or runtime
change returns `Needs_restart`. An unknown dependency rejects the revision.

The adapter compares the manifest with `Host.t` before native mutation. It
copies each build artifact to a package-owned immutable generation path. It
then calls `Dynlink.loadfile_private`.

One private load token authorizes one `Plugin.register` call. Registration
outside a load, no registration, or repeated registration rejects the load.
The token binds the target, stable module locator, artifact, and unique
compilation unit. The registered component family and locator must equal the
target values.

A plugin initializer can only register its inactive declaration. It must not
run component effects. Eta cannot enforce this rule against trusted native
code. Initializer failure records every known artifact residency.

A hot-replaceable component configuration type, coeffect descriptor, and
`Component.Family.t` value must live in the stable host interface. Every native
generation imports the same stable `.cmi` files. A change to these files
requires process restart.

The adapter never unloads native code. Only process restart reclaims all native
generations.

## Callback boundaries

The runtime uses the following exception policy:

| Callback | Execution boundary | Exception result |
| --- | --- | --- |
| Configuration equivalence | Before desired-state or replacement mutation | Typed `Callback_failed`; no lifecycle mutation |
| Interception metadata merge | Before context mutation | Typed `Callback_failed`; no lifecycle mutation |
| Requirement mapping | Inside a fresh activation generation | Generation `Cause.Die` |
| Interception wrapper construction | Inside a fresh activation generation | Generation `Cause.Die` |
| Provision contramapping | Inside a fresh activation generation | Generation `Cause.Die`; no publication |
| Component activation | Inside a fresh activation generation | Generation `Cause.Die` |
| Acquisition or release | Inside the Eta activation scope | Ordinary complete Eta cause |
| Activation-error renderer | After cause settlement | `Renderer_failed`; lifecycle cause unchanged |
| Release-error renderer | During protected finalizer capture | `Renderer_failed`; lifecycle cause unchanged |
| Coeffect value equivalence | Executable contract verification only | Failed contract test |
| Loader preparation | Loader-owned scope before core admission | Immutable loader failure; no core revision |
| Native manifest source | Loader-owned scope before native mutation | Immutable loader failure; no core revision |
| Native initializer | During private native loading | Native-load failure with recorded residency |

The component runtime does not use coeffect value equivalence to select a
provider or preserve an activation generation.

The runtime invokes each failure renderer at most once for one settled failure
leaf. It retains the original same-domain cause. A total internal wrapper
captures a renderer exception and produces stable fallback text.

The loader materializes the complete adapter exit before it completes an
operation report. A preparation defect cannot bypass the immutable report.

## Provider and admission rules

An opaque provider-episode ID is allocated when one generation stages its
complete provision set. The ID has a one-to-one association with that
component instance and generation.

A transaction-local episode can resolve a staged consumer. It becomes
discoverable only at the batch commit. A failed or superseded staging attempt
never becomes discoverable.

Desired-state admission checks every effectively enabled provision
declaration. It does not wait for provider activation. Admission rejects two
prospective providers for one `(coeffect key, realm)` slot.

Admission computes the prospective provider graph from all selected slots.
It rejects every cycle before lifecycle mutation. A missing provider remains
valid and leaves its consumer waiting.

## Target revisions and replacement

Each retained entry has an opaque, context-qualified target revision. The
revision covers:

- the component-instance incarnation.
- enablement.
- component declaration and family identity.
- the stable family module locator.
- the configuration equivalence class.
- the complete effective isolation and interception context.

Reordering does not change the target revision. A move changes it only when
the effective target facts change.

A replacement target carries the expected instance identity and target
revision. Admission rejects the complete batch when either value is stale or
belongs to another context.

Provider availability can change after target preparation. Replacement
admission recomputes the current participant closure and provider graph under
the serialized coordinator.

One source authority assigns strictly increasing `Source_revision.t` values
for one component context. Loader submission and direct replacement admission
reject equal or decreasing revisions before lifecycle mutation.

## Operation and settlement rules

Reconciliation, retry, and replacement can overlap in time. The context
coordinator serializes their admission and every atomic mutation.

A later accepted operation supersedes an earlier operation only for component
instances where it selects a conflicting target. Disjoint operations can both
finish normally.

Each generation records the fence that started it. A later fence can retire or
wait for that generation. Both reports retain the generation with different
participant roles.

A superseded fence waits until all work that it started settles. Clean
settlement returns one immutable `Superseded` report. Recovery or context
failure uses the outcome precedence below. No generation or retained failure
can disappear from every report.

If replacement becomes superseded before publication, the runtime closes every
candidate or restoration attempt. It does not restore an obsolete
pre-mutation target. The latest accepted target starts after settlement.

Rollback publishes the pre-mutation target at one linearization point. A later
operation accepted after that point observes the restored target. The completed
replacement fence remains `Rolled_back`.

Shutdown closes admission for new context operations. It supersedes every
unfinished target, but it waits for all owned scopes. Repeated shutdown calls
return the same fence.

Terminal outcome precedence is:

1. `Context_failed` for a component-runtime invariant failure.
2. `Degraded` for a completed recovery failure that quarantines an instance.
3. `Restoration_failed` for failed restoration activation after clean
   restoration cleanup.
4. `Rolled_back` when candidate failure restores the retained declarations.
5. `Superseded` when a later accepted target prevents the requested target.
6. `Quiescent` when the requested operation reaches a settled legal state.

A clean activation failure can produce `Quiescent`. Its participant and
failure remain in the report and final snapshot.

A completed cleanup failure can finish a reconciliation, retry, or replacement
fence as `Degraded`. Its final snapshot can have progress `Blocked`.

Shutdown remains pending while a retained lease prevents provider settlement.
A nonterminating cleanup keeps progress `Reconciling`. It produces no terminal
report.

## Implementation sequence

Each step adds its public law prose, named executable properties, and registry
rows in one change.

1. **Create the declaration foundation.**
   Add `eta_component`, identities, coeffects, typed schemas, components, and
   pure desired-state builders.
   Verify compiler rejection, schema uniqueness, and package boundaries.
2. **Create the pure semantic oracle.**
   Add commands, observations, identity bijections, and the direct quiescent
   oracle.
   Verify generated graph, outcome, and branch matrices.
3. **Implement generation ownership.**
   Add `Activation.own`, admission fences, Eta scopes, complete cause capture,
   and the instance state machine.
   Verify every prefix with `Eta_test`.
4. **Implement provider coordination.**
   Add slots, realms, committed views, leases, cycle checks, isolation, and
   interception.
   Verify dependent-first settlement and operation-entry snapshots.
5. **Implement context control and reconciliation.**
   Add `Context.run`, desired revisions, target revisions, retries,
   supersession, fences, snapshots, change waits, and shutdown.
   Verify final-snapshot normal forms and operation reports.
6. **Implement replacement.**
   Add target stamps, participant closure, staged views, atomic publication,
   rollback, and restoration.
   Verify the complete replacement outcome matrix.
7. **Create `eta_component_loader`.**
   Add lexical preparation ownership, source supersession, immutable reports,
   and admission linkage.
   Verify that pre-admission rejection changes no core revision.
8. **Create `eta_component_loader_native`.**
   Add manifests, classification, private loading, plugin registration, and
   residency reports.
   Verify each native result in a fresh process.
9. **Add telemetry and cost gates.**
   Add bounded built-in telemetry, compiler probes, and package benchmarks.
   Record production baselines before nonzero allocation or time limits.
10. **Run the complete release gates.**
    Run all install, law, Eta-test, Eio, native-process, and benchmark gates.
    Make sure that every terminal effect path has an available empty census.

## Final verification matrix

The existing property definitions remain in
[Executable laws and reference model](../issues/20-executable-laws-and-reference-model.md).
The integrated contract adds the named properties below.

| Contract area | Named gate | Required discriminating case |
| --- | --- | --- |
| Declaration schemas | `qcheck_component_schema_key_uniqueness` | Duplicate requirement, duplicate provision, and self-dependency fail at `Component.make` |
| Generation admission | `qcheck_component_generation_admission_fence` | A pre-fence acquisition lands after cancellation; a post-fence acquisition is interrupted |
| Provision commit | `qcheck_component_complete_provision_commit` | One stale or incomplete staged set publishes no provision |
| Lifecycle inertia | `qcheck_component_lifecycle_inertia_and_retry` | Several targets arrive during settlement; only the latest target starts |
| Callback classification | `qcheck_component_callback_boundary_matrix` | Every pre-mutation and generation callback raises in one generated sample |
| Recovery | `qcheck_component_recovery_lifo` and `qcheck_component_cleanup_at_most_once` | Partial activation and repeated disposal distinguish order and cardinality |
| Causes and quarantine | `qcheck_component_cause_and_quarantine_matrix` | Primary failure and cleanup failure produce suppression; a hang produces no report |
| Failure locality | `qcheck_component_failure_locality_and_quarantine_fence` | An unrelated sibling stays active while retry cannot cross quarantine |
| Provider ordering | `qcheck_component_provider_withdrawal_order` | The scheduler attempts provider cleanup before consumer cleanup |
| Direct leases | `qcheck_component_direct_lease_cardinality` | Several keys from one episode create one lease; failed cleanup retains it |
| Episode identity | `qcheck_component_episode_identity_bijection` | One staged generation has one opaque episode across views and reports |
| Provider handoff | `qcheck_component_committed_view_coherence` and `qcheck_component_equal_value_episode_reactivation` | Equal values from different episodes still restart the consumer |
| Admission | `qcheck_component_desired_admission_atomic` and `qcheck_component_cycle_rejection_atomic` | A late invalid node changes no accepted fact |
| Realm movement | `qcheck_component_realm_reassignment_atomic` | Joint provider-consumer movement preserves the episode; conflict changes nothing |
| Metadata algebra | `qcheck_component_interception_metadata_identity`, `qcheck_component_interception_metadata_associativity`, and `qcheck_component_interception_fold_order` | Noncommutative metadata distinguishes component, outer, and inner order |
| Operation entry | `qcheck_component_operation_entry_interception` | An update during an operation affects only the next operation |
| Reconciliation | `qcheck_component_reconciliation_prefix_oracle` and `qcheck_component_reconciliation_normal_form` | Detour histories and fresh assembly reach one normalized state |
| Runtime identity | `qcheck_component_reconciliation_identity_rules` | Move preserves identity; re-addition creates a new instance |
| Progress | `qcheck_component_quiescent_progress` | A reverse fair schedule needs repeated scans before release |
| Simultaneous changes | `qcheck_component_simultaneous_update_fence` | No activation observes an old-provider and new-consumer pair |
| Source preparation | `qcheck_component_preparation_revision_fence` | Equal and decreasing revisions reject; an old completion changes no core state |
| Loader lifetime | `eta_test_component_loader_lexical_lifetime` | Body exit settles every accepted loader operation and leaks no preparation work |
| Supersession | `qcheck_component_operation_supersession_attribution` | Two overlapping fences retain every generation with its participant role |
| Degraded settlement | `qcheck_component_degraded_fence_outcomes` | Reconcile finishes `Degraded` while guarded shutdown remains pending |
| Shutdown | `qcheck_component_shutdown_fence_idempotence` | Repeated calls return one fence and run no cleanup twice |
| Lexical context lifetime | `eta_test_component_context_lexical_lifetime` | Body success, failure, and interruption each start shutdown and preserve cause structure |
| Target freshness | `qcheck_component_replacement_target_revision_fence` | Every stamp field, wrong-context target, and locator mismatch fails in each sample |
| Replacement | `qcheck_component_hmr_rollback_matrix` | Candidate activation fails after drainage and restoration uses fresh episodes |
| Outcome precedence | `qcheck_component_replacement_outcome_precedence` | Supersession crosses rollback, restoration failure, recovery failure, and context failure |
| Diagnostics | `qcheck_component_diagnostics_revision_atomicity` | Batch publication changes all visible facts under one revision |
| Change waits | `qcheck_component_change_wait_race_freedom` | A mutation occurs between revision read and waiter registration |
| Reports | `qcheck_component_settlement_report_repeatability` | A removed participant remains in every repeated report |
| Rendering | `qcheck_component_failure_rendering_stability` | A renderer raises without changing the authoritative cause |
| Independence | `qcheck_component_independent_key_commutation` and `qcheck_component_shared_key_commutation` | Both operation orders preserve every required observation |
| Convergence | `qcheck_component_schedule_independent_terminal` | Independent consumers complete in opposite orders |
| Equivalence | `component_equivalence_contracts` | Every coeffect and configuration equivalence is reflexive, symmetric, and transitive |
| Telemetry | `qcheck_component_telemetry_noninterference` | A sink drops every event without changing an authoritative observation |
| Runtime conformance | `eta_test_component_model_conformance` | Every controlled command prefix matches the separate pure model |
| Eio races | `eta_eio_component_adversarial_lifecycle` | Cancellation races acquisition, commit, and dependent cleanup |
| Static typing | `component_static_contract` | Wrong key, configuration, metadata, provision, and release types fail separately |
| Native loading | `native_hmr_process_contract` | Stable digest, family, locator, registration count, and residency each reach every result |
| OxCaml modes | `component_oxcaml_contract` | Portable keys cross; component and context authorities do not cross |
| Cost | `eta_component_bench_contract` | Required zero-allocation paths match production baselines after semantic gates |
| Package boundaries | `eta_component_shipped_package_contract` | Each package installs alone with only its declared dependencies |

The QCheck generators construct every required branch. Counterexamples include
the complete shrunk command trace, observations, causes, and identity mapping.

Every effect-backed terminal path requires an available empty Eta fiber census.
The only temporary exception is a controlled nonterminating cleanup. Its test
releases the cleanup before the final census.

## Handoff verdict

The user approved this coherent, implementation-ready design package.
Production implementation remains outside this wayfinder effort.
