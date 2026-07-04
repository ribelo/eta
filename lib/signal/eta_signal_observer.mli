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
