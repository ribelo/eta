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
  val label : ('live, 'value) t -> string

  val activate :
    ('live, 'value) t ->
    (('live, 'value) t, [> `Invalid_scope ]) result

  val finish :
    value_of_live:('live -> 'value) ->
    finish_reason ->
    ('live, 'value) t ->
    ('live, 'value) finish
end

module Delivery : sig
  type ('a, 'after_ack) t =
    | Observer_never_delivered
    | Observer_delivered of 'a
    | Observer_delivery_pending of int * 'a Update.t * 'after_ack list
    | Observer_delivery_running of int * 'a Update.t * 'after_ack list

  val base : ('a, 'after_ack) t -> 'a option
  val pending : ('a, 'after_ack) t -> bool

  val pending_state :
    token:int -> 'a Update.t -> ('a, 'after_ack) t

  val acknowledge :
    token:int ->
    update:'a Update.t ->
    after_ack:'after_ack list ->
    ('a, 'after_ack) t ->
    (('a, 'after_ack) t * 'after_ack list) option

  val claim :
    token:int -> ('a, 'after_ack) t -> ('a, 'after_ack) t option

  val release :
    token:int -> ('a, 'after_ack) t -> ('a, 'after_ack) t option

  val running_token : ('a, 'after_ack) t -> int option
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
