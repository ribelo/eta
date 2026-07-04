(** Serialized graph-lane acquisition for Eta_signal internals. *)

type t

type hooks = {
  note_waiter_enqueued : unit -> unit;
  note_waiter_compaction : unit -> unit;
}

val create : unit -> t

val enter : hooks:hooks -> Eta.Runtime_contract.t -> t -> unit
val leave : t -> unit

val owner_fiber_id : t -> int option
val set_owner_fiber_id : t -> int option -> unit

val waiting_count : t -> int
val cancelled_count : t -> int

val should_compact_cancelled :
  retained_cancelled:int -> queue_length:int -> bool
