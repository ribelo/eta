(** Observer update and delivery-state helpers for Eta_signal internals. *)

module Update : sig
  type 'a t =
    | Initialized of 'a
    | Changed of {
        old_value : 'a;
        new_value : 'a;
      }

  val delivered_value : 'a t -> 'a
end

module Delivery_handle : sig
  type ('token, 'update, 'after_ack) t

  val create :
    token:'token ->
    update:'update ->
    current_token:
      ('error. unit -> ('token option, 'error) Eta.Effect.t) ->
    acknowledge_sent:
      ('error. 'token -> 'update -> (unit, 'error) Eta.Effect.t) ->
    acknowledge_drop:
      ('error.
       after_ack:'after_ack list ->
       'token ->
       'update ->
       (unit, 'error) Eta.Effect.t) ->
    ('token, 'update, 'after_ack) t

  val token : ('token, _, _) t -> 'token
  val update : (_, 'update, _) t -> 'update

  val current_token :
    ('token, _, _) t -> unit -> ('token option, 'error) Eta.Effect.t

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

  val uninitialized : 'a t
  val current : 'a -> 'a t
  val mark_failed_without_current : 'a t -> 'a t
  val read : 'a t -> ('a, [> `No_current_value | `Uninitialized_observer ]) result
  val unsafe_read_exn : 'a t -> 'a
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

  type ('live, 'value) finish

  val live : ('live, 'value) t -> 'live option
  val active_live : ('live, 'value) t -> 'live option
  val active : ('live, 'value) t -> bool
  val demands : ('live, 'value) t -> bool
  val invalid_scope : ('live, 'value) t -> bool
  val diagnostic_visible :
    include_invalid:bool -> ('live, 'value) t -> bool
  val label : ('live, 'value) t -> string

  val activate :
    ('live, 'value) t ->
    (('live, 'value) t, [> `Invalid_scope ]) result

  val finish :
    value_of_live:('live -> 'value) ->
    finish_reason ->
    ('live, 'value) t ->
    ('live, 'value) finish

  val finish_result :
    ('live, 'value) finish ->
    plan:
      (state:('live, 'value) t ->
      hook_live:'live option ->
      remove:bool ->
      'a) ->
    'a

  val read_value :
    value_of_live:('live -> 'a Value.t) ->
    ('live, 'a Value.t) t ->
    ('a, [> `Disposed_observer | `Invalid_scope | `No_current_value
         | `Uninitialized_observer ])
    result

  val unsafe_read_value_exn :
    value_of_live:('live -> 'a Value.t) -> ('live, 'a Value.t) t -> 'a
end

type ('observer, 'live, 'value, 'hook) lifecycle_port

val lifecycle_port :
  state:('observer -> ('live, 'value) Lifecycle.t) ->
  set_state:('observer -> ('live, 'value) Lifecycle.t -> unit) ->
  value:('live -> 'value) ->
  finish_hooks:('live -> Lifecycle.finish_reason -> 'hook list) ->
  remove:('observer -> unit) ->
  ('observer, 'live, 'value, 'hook) lifecycle_port

val activate_observer :
  ('observer, 'live, 'value, 'hook) lifecycle_port ->
  'observer ->
  ('observer, [> `Invalid_scope ]) result

val finish_observer :
  ('observer, 'live, 'value, 'hook) lifecycle_port ->
  'observer ->
  Lifecycle.finish_reason ->
  'hook list

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

  type ('a, 'after_ack) t =
    | Observer_never_delivered
    | Observer_delivered of 'a
    | Observer_delivery_pending of token * 'a Update.t * 'after_ack list
    | Observer_delivery_running of token * 'a Update.t * 'after_ack list

  type ('a, 'after_ack) finish

  val base : ('a, 'after_ack) t -> 'a option
  val pending : ('a, 'after_ack) t -> bool

  val pending_state :
    token:token -> 'a Update.t -> ('a, 'after_ack) t

  val acknowledge :
    token:token ->
    update:'a Update.t ->
    after_ack:'after_ack list ->
    ('a, 'after_ack) t ->
    (('a, 'after_ack) t * 'after_ack list) option

  val claim :
    token:token -> ('a, 'after_ack) t -> ('a, 'after_ack) t option

  val release :
    token:token -> ('a, 'after_ack) t -> ('a, 'after_ack) t option

  val finish_running :
    token:token ->
    update:'a Update.t ->
    delivered:bool ->
    after_ack:'after_ack list ->
    ('a, 'after_ack) t ->
    ('a, 'after_ack) finish option

  val finish_result :
    ('a, 'after_ack) finish ->
    acknowledged:
      (state:('a, 'after_ack) t -> after_ack:'after_ack list -> 'result) ->
    released:(state:('a, 'after_ack) t -> 'result) ->
    'result

  val running_token : ('a, 'after_ack) t -> token option
  val running_token_matches : token:token -> ('a, 'after_ack) t -> bool
  val label : ('a, 'after_ack) t -> string
end

module Delivery_runner : sig
  type ('event, 'callback, 'error) t
  (** Context for delivering observer events. The runner owns the
      ordering: skip inactive observers, claim before constructing/running a
      callback, acknowledge only after a callback succeeds, release a claim on
      failure or finish an already-delivered callback, then continue to the
      next event. *)

  val create :
    active:('event -> (bool, 'error) Eta.Effect.t) ->
    claim:('event -> (bool, 'error) Eta.Effect.t) ->
    after_claim:(unit -> (unit, 'error) Eta.Effect.t) ->
    construct:('event -> ('callback option, 'error) Eta.Effect.t) ->
    run_callback:('event -> 'callback -> (unit, 'error) Eta.Effect.t) ->
    acknowledge:('event -> (unit, 'error) Eta.Effect.t) ->
    finish_error:
      ('event -> delivered:bool -> (unit, 'error) Eta.Effect.t) ->
    ('event, 'callback, 'error) t

  val run :
    ('event, 'callback, 'error) t ->
    'event list ->
    (unit, 'error) Eta.Effect.t
end

module Delivery_event : sig
  type ('capability, 'callback, 'error) t
  (** Sealed observer delivery event. The event hides the concrete observer
      value/update pair while this module owns the delivery ordering. *)

  val create :
    mark_pending:('capability -> unit) ->
    active:(unit -> (bool, 'error) Eta.Effect.t) ->
    claim:(unit -> (bool, 'error) Eta.Effect.t) ->
    construct:(unit -> ('callback option, 'error) Eta.Effect.t) ->
    run_callback:('callback -> (unit, 'error) Eta.Effect.t) ->
    acknowledge:(unit -> (unit, 'error) Eta.Effect.t) ->
    finish_error:(delivered:bool -> (unit, 'error) Eta.Effect.t) ->
    ('capability, 'callback, 'error) t

  val mark_pending : 'capability -> ('capability, 'callback, 'error) t -> unit

  val run :
    after_claim:(unit -> (unit, 'error) Eta.Effect.t) ->
    ('capability, 'callback, 'error) t list ->
    (unit, 'error) Eta.Effect.t
end

module Snapshot : sig
  type ('a, 'after_ack) t

  type ('a, 'after_ack) finish

  type ('a, 'after_ack) event_plan

  val initial : ('a, 'after_ack) t

  val create :
    value:'a Value.t ->
    delivery:('a, 'after_ack) Delivery.t ->
    ('a, 'after_ack) t

  val value : ('a, 'after_ack) t -> 'a Value.t
  val delivery : ('a, 'after_ack) t -> ('a, 'after_ack) Delivery.t
  val with_value : ('a, 'after_ack) t -> 'a Value.t -> ('a, 'after_ack) t

  val with_delivery :
    ('a, 'after_ack) t ->
    ('a, 'after_ack) Delivery.t ->
    ('a, 'after_ack) t

  val with_pending_delivery :
    token:Delivery.token ->
    'a Update.t ->
    ('a, 'after_ack) t ->
    ('a, 'after_ack) t

  val acknowledge_delivery :
    token:Delivery.token ->
    update:'a Update.t ->
    after_ack:'after_ack list ->
    ('a, 'after_ack) t ->
    (('a, 'after_ack) t * 'after_ack list) option

  val claim_delivery :
    token:Delivery.token ->
    ('a, 'after_ack) t ->
    ('a, 'after_ack) t option

  val release_delivery :
    token:Delivery.token ->
    ('a, 'after_ack) t ->
    ('a, 'after_ack) t option

  val finish_running_delivery :
    token:Delivery.token ->
    update:'a Update.t ->
    delivered:bool ->
    after_ack:'after_ack list ->
    ('a, 'after_ack) t ->
    ('a, 'after_ack) finish option

  val finish_result :
    ('a, 'after_ack) finish ->
    acknowledged:
      (snapshot:('a, 'after_ack) t ->
      after_ack:'after_ack list ->
      'result) ->
    released:(snapshot:('a, 'after_ack) t -> 'result) ->
    'result

  val running_delivery_token_matches :
    token:Delivery.token -> ('a, 'after_ack) t -> bool

  val plan_event :
    equal:('a -> 'a -> bool) ->
    changed:bool ->
    value:'a ->
    ('a, 'after_ack) t ->
    ('a, 'after_ack) event_plan

  val event_plan :
    ('a, 'after_ack) event_plan ->
    plan:
      (snapshot:('a, 'after_ack) t -> update:'a Update.t option -> 'result) ->
    'result
end

type ('capability, 'observer, 'live, 'a, 'after_ack) delivery_port

val delivery_port :
  live:('capability -> 'observer -> 'live option) ->
  snapshot:('capability -> 'live -> ('a, 'after_ack) Snapshot.t) ->
  set_snapshot:
    ('capability -> 'live -> ('a, 'after_ack) Snapshot.t -> unit) ->
  run_after_ack:('capability -> 'after_ack list -> unit) ->
  ('capability, 'observer, 'live, 'a, 'after_ack) delivery_port

val acknowledge_delivery :
  ('capability, 'observer, 'live, 'a, 'after_ack) delivery_port ->
  'capability ->
  'observer ->
  Delivery.token ->
  'a Update.t ->
  after_ack:'after_ack list ->
  unit

val claim_delivery :
  ('capability, 'observer, 'live, 'a, 'after_ack) delivery_port ->
  'capability ->
  'observer ->
  Delivery.token ->
  bool

val finish_delivery_after_error :
  ('capability, 'observer, 'live, 'a, 'after_ack) delivery_port ->
  'capability ->
  'observer ->
  Delivery.token ->
  'a Update.t ->
  delivered:bool ->
  unit

val running_delivery_token_matches :
  ('capability, 'observer, 'live, 'a, 'after_ack) delivery_port ->
  'capability ->
  'observer ->
  Delivery.token ->
  bool

val mark_failed_without_current :
  ('capability, 'observer, 'live, 'a, 'after_ack) delivery_port ->
  'capability ->
  'observer ->
  unit

type ('capability, 'observer, 'a, 'callback, 'error) delivery_event_port

val delivery_event_port :
  active:('capability -> 'observer -> bool) ->
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

val make_delivery_event :
  access:'capability delivery_event_access ->
  ('capability, 'observer, 'live, 'a, 'after_ack) delivery_port ->
  ('capability, 'observer, 'a, 'callback, 'error) delivery_event_port ->
  observer:'observer ->
  token:Delivery.token ->
  'a Update.t ->
  ('capability, 'callback, 'error) Delivery_event.t

type ('capability, 'observer, 'live, 'a, 'after_ack, 'event)
     collection_port

val collection_port :
  live:('capability -> 'observer -> 'live option) ->
  skip:('capability -> 'observer -> bool) ->
  compute:('capability -> 'observer -> 'a * bool) ->
  snapshot:('capability -> 'live -> ('a, 'after_ack) Snapshot.t) ->
  stage_snapshot:
    ('capability -> 'live -> ('a, 'after_ack) Snapshot.t -> unit) ->
  equal:('observer -> 'a -> 'a -> bool) ->
  make_event:('capability -> 'observer -> 'a Update.t -> 'event) ->
  ('capability, 'observer, 'live, 'a, 'after_ack, 'event) collection_port

val collect_event :
  ('capability, 'observer, 'live, 'a, 'after_ack, 'event)
  collection_port ->
  'capability ->
  'observer ->
  'event option
