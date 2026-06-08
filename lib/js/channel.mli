(** Same-runtime bounded channel for eta_js fibers. *)

type ('a, 'err) t

type stats = {
  depth : int;
  sent : int;
  received : int;
  closed : bool;
  waiting_senders : int;
  waiting_receivers : int;
  cancelled_senders : int;
}

type 'err send_result =
  [ `Sent | `Full | `Closed | `Closed_with_error of 'err ]

type ('a, 'err) recv_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]

val create : capacity:int -> unit -> ('a, 'err) t
val send : ('a, 'err) t -> 'a -> (unit, [> `Closed | `Closed_with_error of 'err ]) Effect.t
val recv : ('a, 'err) t -> ('a, [> `Closed | `Closed_with_error of 'err ]) Effect.t
val try_send : ('a, 'err) t -> 'a -> ('err send_result, 'never) Effect.t
val try_recv : ('a, 'err) t -> (('a, 'err) recv_result, 'never) Effect.t
val close : ('a, 'err) t -> unit
val close_with_error : ('a, 'err) t -> 'err -> unit
val stats : ('a, 'err) t -> stats
