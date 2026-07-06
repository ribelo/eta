(** Observer update and delivery-state helpers for Eta_signal internals. *)

module Update : sig
  type 'a t =
    | Initialized of 'a
    | Changed of {
        old_value : 'a;
        new_value : 'a;
      }
end

module Delivery_handle : sig
  type ('token, 'update, 'after_ack) t

  val current :
    ('token, 'update, _) t ->
    unit ->
    (('token * 'update) option, 'error) Eta.Effect.t

  val acknowledge_sent :
    ('token, 'update, _) t ->
    'token ->
    'update ->
    (unit, 'error) Eta.Effect.t

  val acknowledge_drop :
    ('token, 'update, 'after_ack) t ->
    after_ack:'after_ack list ->
    'token ->
    'update ->
    (unit, 'error) Eta.Effect.t
end

module Value : sig
  type 'a t =
    | Uninitialized
    | Current of 'a
    | Failed_without_current

  val label : 'a t -> string
end

module Lifecycle : sig
  type finish_reason =
    | Finish_disposed
    | Finish_invalid_scope

  type ('live, 'value) t =
    | Registering of 'live
    | Active of 'live
    | Disposed of 'value
    | Invalid_scope of 'value

  val active_live : ('live, 'value) t -> 'live option
  val active : ('live, 'value) t -> bool
  val demands : ('live, 'value) t -> bool
  val invalid_scope : ('live, 'value) t -> bool
  val diagnostic_visible :
    include_invalid:bool -> ('live, 'value) t -> bool
  val label : ('live, 'value) t -> string

  val read_value :
    value_of_live:('live -> 'a Value.t) ->
    ('live, 'a Value.t) t ->
    ('a, [> `Disposed_observer | `Invalid_scope | `No_current_value
         | `Uninitialized_observer ])
    result

  val unsafe_read_value_exn :
    value_of_live:('live -> 'a Value.t) -> ('live, 'a Value.t) t -> 'a
end

type ('observer, 'live, 'value) activation_port

val activation_port :
  state:('observer -> ('live, 'value) Lifecycle.t) ->
  set_state:('observer -> ('live, 'value) Lifecycle.t -> unit) ->
  ('observer, 'live, 'value) activation_port

type ('observer, 'live, 'value, 'hook) lifecycle_port

val lifecycle_port :
  state:('observer -> ('live, 'value) Lifecycle.t) ->
  set_state:('observer -> ('live, 'value) Lifecycle.t -> unit) ->
  value:('live -> 'value) ->
  finish_hooks:('live -> Lifecycle.finish_reason -> 'hook list) ->
  remove:('observer -> unit) ->
  ('observer, 'live, 'value, 'hook) lifecycle_port

val activate_observer :
  ('observer, 'live, 'value) activation_port ->
  'observer ->
  ('observer, [> `Invalid_scope ]) result

val dispose_observer :
  ('observer, 'live, 'value, 'hook) lifecycle_port ->
  'observer ->
  'hook list

val invalidate_observer :
  ('observer, 'live, 'value, 'hook) lifecycle_port ->
  'observer ->
  'hook list

module Delivery : sig
  type token = int

  type ('a, 'after_ack) t

  val label : ('a, 'after_ack) t -> string
end

module Delivery_event : sig
  type ('capability, 'callback, 'error) t
  (** Sealed observer delivery event. The event hides the concrete observer
      value/update pair while this module owns the delivery ordering. *)

  val run :
    after_claim:(unit -> (unit, 'error) Eta.Effect.t) ->
    ('capability, 'callback, 'error) t list ->
    (unit, 'error) Eta.Effect.t
end

module Snapshot : sig
  type ('a, 'after_ack) t

  val initial : ('a, 'after_ack) t

  val value : ('a, 'after_ack) t -> 'a Value.t
  val delivery : ('a, 'after_ack) t -> ('a, 'after_ack) Delivery.t
end

type ('capability, 'observer, 'live, 'a, 'after_ack) delivery_port

val delivery_port :
  live:('capability -> 'observer -> 'live option) ->
  snapshot:('capability -> 'live -> ('a, 'after_ack) Snapshot.t) ->
  set_snapshot:
    ('capability -> 'live -> ('a, 'after_ack) Snapshot.t -> unit) ->
  run_after_ack:('capability -> 'after_ack list -> unit) ->
  ('capability, 'observer, 'live, 'a, 'after_ack) delivery_port

val mark_failed_without_current :
  ('capability, 'observer, 'live, 'a, 'after_ack) delivery_port ->
  'capability ->
  'observer ->
  unit

type ('capability, 'observer) delivery_event_activation_plan

val delivery_event_activation_plan :
  active:('capability -> 'observer -> bool) ->
  ('capability, 'observer) delivery_event_activation_plan

type ('capability, 'observer, 'a, 'callback, 'error)
     delivery_event_callback_plan

val delivery_event_callback_plan :
  construct:
    ('capability ->
    'observer ->
    Delivery.token ->
    'a Update.t ->
    ('callback option, 'error) result) ->
  run_callback:
    ('observer ->
    Delivery.token ->
    'callback ->
    (unit, 'error) Eta.Effect.t) ->
  ('capability, 'observer, 'a, 'callback, 'error)
  delivery_event_callback_plan

type ('capability, 'observer, 'a, 'callback, 'error) delivery_event_port

val delivery_event_port :
  activation:('capability, 'observer) delivery_event_activation_plan ->
  callback:
    ('capability, 'observer, 'a, 'callback, 'error)
    delivery_event_callback_plan ->
  ('capability, 'observer, 'a, 'callback, 'error) delivery_event_port

type 'capability delivery_event_access

val delivery_event_access :
  with_delivery_access:
    ('a 'error. ('capability -> 'a) -> ('a, 'error) Eta.Effect.t) ->
  'capability delivery_event_access

val make_delivery_handle :
  access:'capability delivery_event_access ->
  ('capability, 'observer, 'live, 'a, 'after_ack) delivery_port ->
  observer:'observer ->
  token:Delivery.token ->
  'a Update.t ->
  (Delivery.token, 'a Update.t, 'after_ack) Delivery_handle.t

type ('capability, 'observer, 'live, 'a, 'after_ack, 'callback, 'error)
     delivery_event_context

val delivery_event_context :
  access:'capability delivery_event_access ->
  delivery:('capability, 'observer, 'live, 'a, 'after_ack) delivery_port ->
  event:('capability, 'observer, 'a, 'callback, 'error) delivery_event_port ->
  token:('capability -> Delivery.token) ->
  ('capability, 'observer, 'live, 'a, 'after_ack, 'callback, 'error)
  delivery_event_context

type ('capability, 'observer, 'live, 'a, 'after_ack, 'event)
     collection_port

val update_collection_port :
  live:('capability -> 'observer -> 'live option) ->
  skip:('capability -> 'observer -> bool) ->
  compute:('capability -> 'observer -> 'a * bool) ->
  snapshot:('capability -> 'live -> ('a, 'after_ack) Snapshot.t) ->
  stage_snapshot:
    ('capability -> 'live -> ('a, 'after_ack) Snapshot.t -> unit) ->
  equal:('observer -> 'a -> 'a -> bool) ->
  ('capability, 'observer, 'live, 'a, 'after_ack, 'a Update.t)
  collection_port

type ('capability, 'observer, 'event) delivery_collection

type 'observer delivery_selection_plan

val delivery_selection_plan :
  active:('observer -> bool) ->
  compare:('observer -> 'observer -> int) ->
  'observer delivery_selection_plan

type ('capability, 'observer, 'callback, 'error) delivery_event_source

val delivery_event_source :
  ('capability, 'observer, 'live, 'a, 'after_ack, 'callback, 'error)
  delivery_event_context ->
  ('capability, 'observer, 'live, 'a, 'after_ack, 'a Update.t)
  collection_port ->
  ('capability, 'observer, 'callback, 'error) delivery_event_source

val delivery_event_source_of_collect_event :
  collect_event:
    ('capability ->
    'observer ->
    ('capability, 'callback, 'error) Delivery_event.t option) ->
  ('capability, 'observer, 'callback, 'error) delivery_event_source

val collect_delivery_event :
  ('capability, 'observer, 'callback, 'error) delivery_event_source ->
  'capability ->
  'observer ->
  ('capability, 'callback, 'error) Delivery_event.t option

val delivery_event_collection :
  selection:'observer delivery_selection_plan ->
  ('capability, 'observer, 'callback, 'error) delivery_event_source ->
  ('capability, 'observer,
   ('capability, 'callback, 'error) Delivery_event.t)
  delivery_collection

val delivery_plan :
  capability:('context -> 'capability) ->
  make_plan:
    (observers:'observer list ->
    collect_events:('context -> 'observer list -> 'event list) ->
    mark_events_pending:('context -> 'event list -> unit) ->
    'plan) ->
  ('capability, 'observer, 'event) delivery_collection ->
  observers:'observer list ->
  'plan
