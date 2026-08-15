(** Spatiotemporal component runtime for Eta.

    An author declares a {!Component}: a reusable declaration with a typed
    configuration, a typed requirement schema, a typed provision schema, an
    activation-error renderer, and one activation effect. An application
    builds an immutable {!Desired_state} tree of groups and entries and
    submits it to one component context created by {!Context.run}. The
    context is the single lifecycle authority: it admits whole snapshots,
    rejects duplicate providers and dependency cycles before it mutates
    anything, resolves each activation against one immutable committed
    provider view, publishes a complete provision set at one commit point,
    and withdraws dependents before their providers. After an accepted
    reconcile settles quiescently, every enabled entry is active and every
    disabled or absent entry has settled.

    Every accepted context operation returns one settlement fence whose
    terminal report is immutable and repeatable. A read-only {!Diagnostics.t}
    supplies atomic snapshots and coalesced change waits. Failure is never
    silent: an activation failure stays local to one instance and retains its
    complete Eta cause, a recovery failure quarantines that instance and
    degrades the context, and a runtime invariant violation fails the whole
    context with its cause.

    This package installs with no Eio, serialization, file-watch, dynlink, or
    test-framework dependency. No mutable component instance, provider,
    supervisor, fiber, switch, cancellation value, or runtime token appears
    in any public type. The runtime seam is {!Eta.Supervisor.scoped}: a
    backend adapter such as [eta_eio] interprets the effect in production and
    [eta_test] interprets the same effect deterministically. *)

open Eta

(** Typed coeffect contracts.

    A coeffect key is a fresh generative identity; the diagnostic name never
    participates in identity. Two coeffects that share a value type and have
    different identities are different keys. Provider selection and
    activation-generation preservation use provider-episode identity, never
    coeffect value equivalence. Value equivalence is used only in executable
    recovery-contract verification. *)
module Coeffect : sig
  type 'value contract
  type 'value t = 'value contract

  val create :
    name:string ->
    equivalent:('value -> 'value -> bool) ->
    unit ->
    'value t
  (** Allocate one fresh generative key identity, retain one diagnostic name,
      and retain one value-equivalence function. *)

  val name : _ t -> string

  module Interception : sig
    type ('value, 'metadata) t
    (** One typed interception descriptor: one metadata type, one empty
        metadata value, one associative merge operation with that empty value
        as its identity, and one value wrapper that receives an
        operation-entry metadata sample. Each descriptor derives exactly one
        coeffect contract. Interception metadata declared for a coeffect
        without a descriptor is rejected at compile time. *)

    val create :
      name:string ->
      equivalent:('value -> 'value -> bool) ->
      empty:'metadata ->
      merge:('metadata -> 'metadata -> 'metadata) ->
      wrap:(sample:(unit -> 'metadata) -> 'value -> 'value) ->
      unit ->
      ('value, 'metadata) t

    val coeffect : ('value, 'metadata) t -> 'value contract
  end
end

(** Typed requirement schemas. *)
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
  (** These are the only requirement constructors. A requirement value whose
      OCaml type does not match its coeffect value type is rejected at
      compile time. *)
end

(** Typed provision schemas. *)
module Provision : sig
  type 'output t

  val none : unit t
  val one : 'value Coeffect.t -> 'value t
  val both : 'left t -> 'right t -> ('left * 'right) t
  val contramap : ('output -> 'staged) -> 'staged t -> 'output t
  (** These are the only provision constructors. *)
end

(** Tracked activation ownership.

    [Activation.t] is the narrow handle handed to component activation code.
    It exposes no registry, dynamic lookup, publication operation,
    child-installation operation, context authority, runtime token, or
    lifecycle handle. *)
module Activation : sig
  type t

  val own :
    t ->
    acquire:('resource, 'acquire_error) Effect.t ->
    release:('resource -> (unit, 'release_error) Effect.t) ->
    pp_release_error:(Format.formatter -> 'release_error -> unit) ->
    ('resource, 'acquire_error) Effect.t
  (** [own activation ~acquire ~release ~pp_release_error] admits one tracked
      effect for the current activation generation.

      - A stale generation or closed admission is reported as requested
        lifecycle interruption; the acquisition-error type is not widened.
      - A successful acquisition registers its release with the current Eta
        activation scope before the operation returns, including an
        acquisition that lands after cancellation was requested.
      - A failed acquisition registers no release; every release from an
        earlier successful acquisition still runs.
      - Each registered release runs at most once, including when it fails.
      - Releases of one activation run serially in reverse registration
        order; a failed release does not stop later releases, and its failure
        is retained in the Eta finalizer cause.
      - [pp_release_error] runs at most once for one settled failure leaf. If
        it raises, the runtime produces a [Renderer_failed] diagnostic and
        leaves the authoritative finalizer cause unchanged.
      - Every specialized component ownership operation is implemented
        through [own]. No default cleanup timeout is added to a release. *)
end

(** Component declarations. *)
module Component : sig
  module Family : sig
    type 'config t

    val create : name:string -> module_locator:string -> unit -> 'config t
    (** Allocate one stable component family with a diagnostic name and one
        stable module locator. *)

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
      ('provisions, 'error) Effect.t) ->
    ('config t, declaration_error) result
  (** Bind one family, one configuration-equivalence function, one
      requirement schema, one provision schema, one activation-error
      renderer, and one activation function into a declaration whose only
      remaining type parameter is its configuration type. Requirement,
      provision, and activation-error types are existential after [make].

      Schema keys are checked without running any caller callback. One schema
      declaring the same coeffect key twice returns [Duplicate_requirement]
      or [Duplicate_provision] with that coeffect name; one declaration
      requiring and providing the same key returns [Self_dependency]. When
      several declaration errors exist, the first error in declaration order
      is returned.

      No public [start], [stop], or recovery operation exists on a component
      declaration. *)

  val family : 'config t -> 'config Family.t
  val pack : 'config t -> packed
  (** Hide the configuration type for heterogeneous loading. *)
end

(** Application-owned stable entry identifiers. *)
module Entry_id : sig
  type t

  val of_string : string -> (t, [ `Invalid_entry_id ]) result
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

(** Immutable desired-state construction.

    Building a desired-state value performs no loading, admission, effect
    execution, or reconciliation. Every group and component entry carries one
    application-owned stable {!Entry_id.t}; child position is structural
    data, not identity. *)
module Desired_state : sig
  module Realm : sig
    type t

    val create : name:string -> unit -> t
    (** Allocate one opaque generative realm identity. *)

    val name : t -> string
  end

  module Context_spec : sig
    type t

    val empty : t

    val isolate : 'value Coeffect.t -> Realm.t -> t -> t
    (** Bind one coeffect key to one realm for a node and its descendants. *)

    val intercept :
      ('value, 'metadata) Coeffect.Interception.t ->
      'metadata ->
      t ->
      t
    (** Add typed metadata for one interceptable coeffect for a node and its
        descendants. Metadata folds in one order: component-declared metadata
        first, then context layers outermost to innermost; the interception
        wrapper observes the merged metadata. *)
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
    (** Pair one component declaration with one matching configuration. An
        entry whose configuration type does not match its component
        configuration type is rejected at compile time. *)

    val id : _ t -> Entry_id.t
  end

  type node
  type t

  val component : _ Entry.t -> node
  (** Hide the configuration type of one entry in the resulting node. *)

  val group :
    id:Entry_id.t ->
    enabled:bool ->
    context:Context_spec.t ->
    node list ->
    node
  (** A group node carries enablement and one context specification and
      creates no component instance. *)

  val tree : node list -> t
end

(** Source revisions stamp replacement batches. *)
module Source_revision : sig
  type t

  val of_int64 : int64 -> t
  val equal : t -> t -> bool
  val compare : t -> t -> int
  val pp : Format.formatter -> t -> unit
end

(** Immutable diagnostics observations.

    Snapshots, change waits, settlement fences, and opaque retained failures.
    Snapshots exclude component configuration, provision values, coeffect
    values, interception metadata, and native module handles. Every public
    identity supports equality, comparison, and formatting, and supports no
    parsing or lifecycle mutation. *)
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
    (** One opaque retained failure. The authoritative failure stays an
        existential same-domain ['error Cause.t]; the public interface does
        not unpack it. *)

    type renderer_failure

    type rendering = {
      pretty : string;
      compact : string;
      portable : string Cause.Portable.t;
    }

    type render_result =
      | Rendered of rendering
      | Renderer_failed of renderer_failure

    val rendering : t -> render_result
    (** When a cause settles, each typed failure leaf is rendered at most
        once; pretty, compact, and portable projections are derived from that
        rendered cause. If a renderer raises, the original cause is retained
        and [Renderer_failed] is exposed; the lifecycle cause is unchanged. *)

    val pp : Format.formatter -> t -> unit
    val pp_compact : Format.formatter -> t -> unit
    (** Both use captured text and invoke no component code or retained error
        printer. *)

    val pp_renderer_failure : Format.formatter -> renderer_failure -> unit
  end

  type lifecycle =
    | Running
    | Stopping
    | Stopped

  type progress =
    | Quiescent  (** No accepted lifecycle work remains. *)
    | Reconciling  (** An admitted operation can still progress. *)
    | Blocked  (** No legal lifecycle step can release an incomplete fence. *)

  type integrity =
    | Sound
    | Degraded of Instance_id.t list
    | Failed of Failure.t
  (** [Sound] when no instance is quarantined and no runtime invariant
      failed; [Degraded] with every quarantined instance identity; [Failed]
      with the complete context-invariant failure. An activation failure
      alone never degrades integrity. No aggregate availability value is
      exposed. *)

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

  val context_id : snapshot -> Context_id.t
  val revision : snapshot -> revision
  val accepted_desired_revision : snapshot -> Desired_revision.t option
  val lifecycle : snapshot -> lifecycle
  val progress : snapshot -> progress
  val integrity : snapshot -> integrity
  val instances : snapshot -> instance list
  (** Instances are ordered by desired-tree order; retained settling
      instances follow active desired entries in retirement order. *)

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
    (** One fence completes with the first applicable outcome in the order
        [Context_failed], [Degraded], [Restoration_failed], [Rolled_back],
        [Superseded], [Quiescent]. *)

    type participant_role =
      | Started
      | Retired
      | Restored
      | Waited

    val id : t -> Fence_id.t

    val await : t -> (report, 'error) Effect.t
    (** Wait for the terminal report. Repeated waits on one settled fence
        return the same terminal report. *)

    val report_id : report -> Fence_id.t
    val kind : report -> kind
    val admitted_at : report -> revision
    val completed_at : report -> revision
    val outcome : report -> outcome
    val final_snapshot : report -> snapshot
    val participants : report -> participant list
    (** Every operation participant remains in the terminal report after
        that participant leaves current state. *)

    val failures : report -> Failure.t list

    val participant_entry : participant -> Entry_id.t
    val participant_instance : participant -> Instance_id.t
    val participant_roles : participant -> participant_role list
    val participant_generations : participant -> Generation_id.t list
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

  type t
  (** One read-only diagnostics value belonging to one lexical component
      context lifetime. It grants no reconcile, retry, replace, or shutdown
      authority. *)

  val snapshot : t -> (snapshot, 'error) Effect.t
  (** One atomic projection of the serialized coordinator state. Reading
      diagnostics creates no semantic lifecycle event. *)

  val await_change : t -> after:revision -> (change, await_error) Effect.t
  (** Wait for a later snapshot. A stale same-context revision for a live
      context returns the latest snapshot immediately; the current revision
      waits for a later snapshot; any valid same-context revision for a
      closed context returns [Closed] with the final snapshot immediately; a
      foreign revision returns [Wrong_context]; a future same-context
      revision returns [Invalid_revision]. Revision read and waiter
      registration are one atomic coordinator operation; several waiters on
      one revision receive the same later snapshot; intermediate revisions
      coalesce; cancelling the waiting effect stops only that effect. No
      public lifecycle event history or journal is exposed. *)
end

(** Replacement targets, candidates, and batches. *)
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
  (** Construct one replacement target from one desired-state entry, one
      expected instance identity, and one expected target revision. *)

  val pack_target : 'config target -> packed_target

  val candidate :
    target:'config target ->
    component:'config Component.t ->
    (candidate, candidate_error) result

  val loaded_candidate :
    target:packed_target ->
    component:Component.packed ->
    (candidate, candidate_error) result
  (** A candidate whose family or configuration identity differs from its
      target returns [Component_identity_mismatch] with that entry
      identifier. *)

  val batch :
    source_revision:Source_revision.t ->
    candidate list ->
    (batch, batch_error) result
  (** Stamp every replacement batch with one source revision. An empty batch
      returns [Empty_batch]; a repeated entry identifier returns
      [Duplicate_entry]. *)
end

(** The component context: the single lifecycle authority. *)
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
    (t -> Diagnostics.t -> ('value, 'error) Effect.t) ->
    ('value, 'error) Effect.t
  (** Create one component context with one fresh context identity inside one
      lexical lifetime and supply that context authority and one read-only
      {!Diagnostics.t} to the body.

      When the body returns, fails, or is interrupted, the context starts
      shutdown and waits for every owned scope to settle before the effect
      completes; the body cause is preserved under Eta finalizer and
      suppression rules. The complete component context stays inside one
      [run] lifetime and never survives across separate [Runtime.run] calls. *)

  val reconcile :
    t ->
    Desired_state.t ->
    (Diagnostics.Fence.t, admission_error) Effect.t

  val retry :
    t ->
    Entry_id.t ->
    (Diagnostics.Fence.t, admission_error) Effect.t
  (** A context-level retry selects a fresh retry generation for one entry
      and exposes no component-instance handle. An entry with no retryable
      failed instance returns [Retry_not_available]; a quarantined instance
      returns [Quarantined_instance]. *)

  val replace :
    t ->
    Replacement.batch ->
    (Diagnostics.Fence.t, admission_error) Effect.t
  (** One admitted batch installs every candidate declaration, then settles
      the replaced generations in consumer-first order before candidate
      activation. A failed candidate activation rolls the batch back: the
      saved pre-mutation declarations and target revisions are restored
      together, restoration reactivates the saved declarations, and the fence
      completes [Rolled_back]. A failed restoration completes the fence
      [Restoration_failed] and publishes no restored provision set. *)

  val shutdown : t -> (Diagnostics.Fence.t, admission_error) Effect.t
  (** [reconcile], [retry], [replace], and [shutdown] are the only context
      operations. Every accepted operation returns one settlement fence.
      Admission validation runs before any lifecycle mutation: a rejected
      admission returns one typed [admission_error], creates no settlement
      fence, and changes no accepted desired state, component instance,
      provider binding, or observation revision.

      The first shutdown request creates one shutdown fence and closes
      admission for every other context operation; a repeated shutdown
      request returns the existing fence and starts no additional cleanup
      pass; a non-shutdown operation after shutdown started returns
      [Context_not_running]. Shutdown supersedes every unfinished target and
      waits for every owned scope. Admission of every context operation and
      every atomic state mutation is serialized through one context
      coordinator. *)
end
