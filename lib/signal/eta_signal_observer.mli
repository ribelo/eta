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
  type ('token, 'update, 'after_ack) t = {
    token : 'token;
    update : 'update;
    current_token :
      'error. unit -> ('token option, 'error) Eta.Effect.t;
    acknowledge_sent :
      'error. 'token -> 'update -> (unit, 'error) Eta.Effect.t;
    acknowledge_drop :
      'error.
      after_ack:'after_ack list ->
      'token ->
      'update ->
      (unit, 'error) Eta.Effect.t;
  }
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

  type ('live, 'value) finish = {
    state : ('live, 'value) t;
    hook_live : 'live option;
    remove : bool;
  }

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

  val read_value :
    value_of_live:('live -> 'a Value.t) ->
    ('live, 'a Value.t) t ->
    ('a, [> `Disposed_observer | `Invalid_scope | `No_current_value
         | `Uninitialized_observer ])
    result

  val unsafe_read_value_exn :
    value_of_live:('live -> 'a Value.t) -> ('live, 'a Value.t) t -> 'a
end

module Delivery : sig
  type token = int

  type ('a, 'after_ack) t =
    | Observer_never_delivered
    | Observer_delivered of 'a
    | Observer_delivery_pending of token * 'a Update.t * 'after_ack list
    | Observer_delivery_running of token * 'a Update.t * 'after_ack list

  type ('a, 'after_ack) finish =
    | Finish_acknowledged of ('a, 'after_ack) t * 'after_ack list
    | Finish_released of ('a, 'after_ack) t

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

  val running_token : ('a, 'after_ack) t -> token option
  val running_token_matches : token:token -> ('a, 'after_ack) t -> bool
  val label : ('a, 'after_ack) t -> string
end

module Snapshot : sig
  type ('a, 'after_ack) t

  type ('a, 'after_ack) finish =
    | Finish_acknowledged of ('a, 'after_ack) t * 'after_ack list
    | Finish_released of ('a, 'after_ack) t

  type ('a, 'after_ack) event_plan = {
    snapshot : ('a, 'after_ack) t;
    update : 'a Update.t option;
  }

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

  val running_delivery_token_matches :
    token:Delivery.token -> ('a, 'after_ack) t -> bool

  val plan_event :
    equal:('a -> 'a -> bool) ->
    changed:bool ->
    value:'a ->
    ('a, 'after_ack) t ->
    ('a, 'after_ack) event_plan
end

module Event : sig
  type ('a, 'after_ack) plan = {
    value : 'a Value.t;
    update : 'a Update.t option;
    delivery : ('a, 'after_ack) Delivery.t option;
  }

  val plan :
    equal:('a -> 'a -> bool) ->
    changed:bool ->
    value:'a ->
    ('a, 'after_ack) Delivery.t ->
    ('a, 'after_ack) plan
end
