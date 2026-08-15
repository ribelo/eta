module Incoming : sig
  type 'incoming t

  val create :
    send:
      (Eta_crux.Projection.Snapshot.t ->
       'incoming ->
       (unit, Eta_crux.Endpoint.admission_error) Eta.Effect.t) ->
    'incoming t

  val none : Eta_crux.never t
end

module Test_shell : sig
  type 'error t = {
    pp_error : Format.formatter -> 'error -> unit;
    deliver :
      Eta_crux.Adapter.delivery ->
      (unit, 'error) Eta.Effect.t;
    request_event :
      Eta_crux.Request.Driver_event.t ->
      (unit, 'error) Eta.Effect.t;
    crash_detected :
      Eta_crux.Failure.t ->
      (unit, 'error) Eta.Effect.t;
  }
end

module Handle : sig
  type 'incoming t
  type operation_error = Busy
  type inject_error = No_projection | Ingress_closed

  type frame_outcome =
    | Idle
    | Rejected of Eta_crux.Root.delivery_error
    | Committed of Eta_crux.Projection.Snapshot.t
    | Stopped
    | Crashed of Eta_crux.Failure.settlement

  type frame = {
    outcome : frame_outcome;
    events : Eta_crux.Driver.event list;
  }

  type drain_status =
    | Idle
    | Limit_reached
    | Closed of Eta_crux.Driver.terminal

  type drain = {
    status : drain_status;
    events : Eta_crux.Driver.event list;
  }

  val create :
    clock:Eta_test.Test_clock.t ->
    incoming:'incoming Incoming.t ->
    shell:'shell_error Test_shell.t ->
    Eta_crux.Root.t ->
    'incoming t

  val use :
    clock:Eta_test.Test_clock.t ->
    incoming:'incoming Incoming.t ->
    shell:'shell_error Test_shell.t ->
    Eta_crux.Root.t ->
    f:
      ('incoming t ->
       ('result, 'body_error) Eta.Effect.t) ->
    ('result, 'body_error) Eta.Effect.t

  val latest_committed_snapshot :
    'incoming t -> Eta_crux.Projection.Snapshot.t option

  val latest_delivered_snapshot :
    'incoming t -> Eta_crux.Projection.Snapshot.t option

  val advance_time_by :
    'incoming t -> Eta.Duration.t -> unit

  val advance_time_to : 'incoming t -> int -> unit

  val inject :
    'incoming t ->
    'incoming ->
    (unit, inject_error) Eta.Effect.t

  val frame :
    'incoming t ->
    ((frame, operation_error) result, Eta_crux.never)
    Eta.Effect.t

  val drain :
    'incoming t ->
    max_steps:int ->
    ((drain, operation_error) result, Eta_crux.never)
    Eta.Effect.t

  val stop :
    'incoming t ->
    ((Eta_crux.Driver.terminal, operation_error) result,
     Eta_crux.never)
    Eta.Effect.t

  val poll :
    'incoming t ->
    ((Eta_crux.Driver.event option, operation_error) result,
     Eta_crux.never)
    Eta.Effect.t

  val await :
    'incoming t ->
    ((Eta_crux.Driver.event, operation_error) result,
     Eta_crux.never)
    Eta.Effect.t

  val delivery_delivered :
    'incoming t ->
    Eta_crux.Driver.Delivery.t ->
    ((unit, Eta_crux.Driver.Delivery.completion_error) result,
     Eta_crux.never)
    Eta.Effect.t

  val delivery_failed :
    'incoming t ->
    Eta_crux.Driver.Delivery.t ->
    Eta_crux.Failure.Packed_cause.t ->
    ((unit, Eta_crux.Driver.Delivery.completion_error) result,
     Eta_crux.never)
    Eta.Effect.t

  val request_stop : 'incoming t -> unit
end

module Post_commit_effect_observer : sig
  module Effect_id = Eta_crux.Testing.Effect_id
  module Commit_index = Eta_crux.Testing.Commit_index
  module Event_position = Eta_crux.Testing.Event_position

  type settlement = Eta_crux.Testing.settlement =
    | Succeeded
    | Interrupted
    | Failed

  type event = Eta_crux.Testing.event =
    | Staged of {
        position : Event_position.t;
        commit : Commit_index.t;
        effects : Effect_id.t list;
      }
    | Started of {
        position : Event_position.t;
        effect : Effect_id.t;
      }
    | Settled of {
        position : Event_position.t;
        effect : Effect_id.t;
        settlement : settlement;
      }
    | Discarded_before_start of {
        position : Event_position.t;
        effect : Effect_id.t;
      }

  type t

  val effect_id_of : event -> Effect_id.t option
  (** The effect identity carried by [Started], [Settled], and
      [Discarded_before_start] events. [Staged] events carry an inventory
      instead of one identity.

      Consumers whose toolchain reserves the [effect] keyword use this
      accessor instead of matching on the record label. *)

  val create : unit -> t
  val attachment : t -> Eta_crux.Testing.post_commit_effect_observer
  val poll : t -> event option
  val drain : t -> event list
  val expect_empty : t -> unit
end

module Projection_harness : sig
  type ('key, 'value) keyed
  type 'value t

  val create :
    name:string ->
    codec:'value Eta_crux.Codec.t ->
    value_equal:('value -> 'value -> bool) ->
    cutoff:'value Eta_crux.Cutoff.t ->
    'value t

  val publish : 'value t -> 'value Eta_crux.t -> 'value Eta_crux.t

  val root :
    ?post_commit_effect_observer:Eta_crux.Testing.post_commit_effect_observer ->
    'value t ->
    projection_capacity:int ->
    ingress_capacity:int ->
    request_capacity:int ->
    'value Eta_crux.t ->
    Eta_crux.Root.t

  val seed_incarnation_counter :
    Eta_crux.Root.t -> int64 -> unit

  val snapshot_value :
    'value t ->
    Eta_crux.Projection.Snapshot.t ->
    'value option

  val commit_value :
    'value t ->
    Eta_crux.Projection.Commit.t ->
    'value option

  val delivery_value :
    'value t ->
    Eta_crux.Projection.delivery ->
    'value option

  module Keyed : sig
    type ('key, 'value) t = ('key, 'value) keyed

    val create :
      name:string ->
      key_compare:('key -> 'key -> int) ->
      key_codec:'key Eta_crux.Codec.t ->
      value_codec:'value Eta_crux.Codec.t ->
      value_equal:('value -> 'value -> bool) ->
      cutoff:'value Eta_crux.Cutoff.t ->
      ('key, 'value) t

    val catalog :
      ('key, 'value) t -> Eta_crux.Projection.Catalog.t

    val publish :
      ('key, 'value) t ->
      key:'key ->
      'value Eta_crux.t ->
      'value Eta_crux.t

    val snapshot_find_opt :
      ('key, 'value) t ->
      key:'key ->
      Eta_crux.Projection.Snapshot.t ->
      ('key, 'value) Eta_crux.Projection.entry option

    val batch_find_opt :
      ('key, 'value) t ->
      key:'key ->
      Eta_crux.Projection.Batch.t ->
      ('key, 'value) Eta_crux.Projection.update list
  end

  module Wire_recipient : sig
    type rejection =
      | Unknown_kind
      | Invalid_key
      | Noncanonical_key
      | Zero_incarnation
      | Noncanonical_order
      | Duplicate_identity
      | Invalid_transition
      | Codec_error
      | Capacity_exceeded
      | Install_failed

    type ('key, 'value) t

    val create :
      ('key, 'value) keyed ->
      capacity:int ->
      ('key, 'value) t

    val fail_next_install : ('key, 'value) t -> unit
    val installed : ('key, 'value) t -> bool
    val delivered_count : ('key, 'value) t -> int
    val find_value : ('key, 'value) t -> key:'key -> 'value option
    val find_incarnation : ('key, 'value) t -> key:'key -> int64 option

    val apply :
      ('key, 'value) t ->
      Eta_crux.Wire.Frame.t ->
      (unit, rejection) result
  end

  module Opaque : sig
    val root :
      ?post_commit_effect_observer:Eta_crux.Testing.post_commit_effect_observer ->
      projection_capacity:int ->
      ingress_capacity:int ->
      request_capacity:int ->
      'value Eta_crux.t ->
      Eta_crux.Root.t

    val snapshot_value :
      Eta_crux.Projection.Snapshot.t ->
      'value option

    val commit_value :
      Eta_crux.Projection.Commit.t ->
      'value option

    val delivery_value :
      Eta_crux.Projection.delivery ->
      'value option
  end
end


module Controlled_source : sig
  type ('spec, 'item, 'error) t
  type ('spec, 'item, 'error) incarnation

  type state =
    | Opening
    | Running
    | Completed
    | Failed
    | Cancelled

  type control_error = Wrong_state of state

  type emit_error =
    | Control of control_error
    | Admission of Eta_crux.Endpoint.admission_error

  val create : unit -> ('spec, 'item, 'error) t

  val producer :
    ('spec, 'item, 'error) t ->
    'spec ->
    ('item, 'error) Eta_crux.Source.producer

  val poll_incarnation :
    ('spec, 'item, 'error) t ->
    ('spec, 'item, 'error) incarnation option

  val await_incarnation :
    ('spec, 'item, 'error) t ->
    (('spec, 'item, 'error) incarnation, Eta_crux.never)
    Eta.Effect.t

  val spec : ('spec, 'item, 'error) incarnation -> 'spec
  val state : ('spec, 'item, 'error) incarnation -> state

  val open_ :
    ('spec, 'item, 'error) incarnation ->
    (unit, control_error) result

  val fail_open :
    ('spec, 'item, 'error) incarnation ->
    'error ->
    (unit, control_error) result

  val emit :
    ('spec, 'item, 'error) incarnation ->
    'item ->
    (unit, emit_error) Eta.Effect.t

  val complete :
    ('spec, 'item, 'error) incarnation ->
    (unit, control_error) result

  val fail :
    ('spec, 'item, 'error) incarnation ->
    'error ->
    (unit, control_error) result

  val captured_emitter :
    ('spec, 'item, 'error) incarnation ->
    'item Eta_crux.Source.emit option

  val expect_no_pending : ('spec, 'item, 'error) t -> unit
end

module Recording_adapter : sig
  type event =
    | Acquire
    | Deliver of Eta_crux.Adapter.delivery
    | Request_event of Eta_crux.Request.Driver_event.t
    | Crash_detected of Eta_crux.Failure.t
    | Release

  type 'error t

  val create :
    pp_error:(Format.formatter -> 'error -> unit) ->
    'error t

  val resource :
    'error t ->
    'error Eta_crux.Adapter.resource

  val acquire_control :
    'error t ->
    (unit, unit, 'error) Eta_test.Controlled.t

  val release_control :
    'error t ->
    (unit, unit, 'error) Eta_test.Controlled.t

  val delivery_control :
    'error t ->
    (Eta_crux.Adapter.delivery, unit, 'error)
    Eta_test.Controlled.t

  val request_control :
    'error t ->
    (Eta_crux.Request.Driver_event.t, unit, 'error)
    Eta_test.Controlled.t

  val crash_control :
    'error t ->
    (Eta_crux.Failure.t, unit, 'error) Eta_test.Controlled.t

  val events : 'error t -> event list
end
