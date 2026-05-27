(** Same-domain unbounded queue.

    Queue is an Eta-owned producer/consumer primitive for handoff between
    fibers when capacity backpressure is not part of the contract. It owns the
    close fence: after [close] or [close_with_error], future sends are rejected
    and already buffered values remain drainable before receivers observe the
    close reason. *)

type ('a, 'err) t

type stats = {
  depth : int;
  sent : int;
  received : int;
  closed : bool;
  waiting_receivers : int;
  cancelled_receivers : int;
}

type 'err send_result = [ `Sent | `Closed | `Closed_with_error of 'err ]
type ('a, 'err) recv_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]

val create : unit -> ('a, 'err) t
val unbounded : unit -> ('a, 'err) t
(** Alias for {!create}. *)

val send :
  ('a, 'err) t ->
  'a ->
  (unit, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Enqueue a value unless the queue is closed. *)

val recv :
  ('a, 'err) t ->
  ('a, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Receive the next value, waiting while the queue is empty.

    Buffered values are delivered after close. Once the buffer is drained,
    [close] fails with [`Closed] and [close_with_error err] fails with
    [`Closed_with_error err]. *)

val try_send : ('a, 'err) t -> 'a -> ('err send_result, 'never) Effect.t
(** Try to enqueue without waiting. Unbounded queues never return [`Full]. *)

val try_recv : ('a, 'err) t -> (('a, 'err) recv_result, 'never) Effect.t
(** Try to receive without waiting. *)

val close : ('a, 'err) t -> unit
(** Close the queue cleanly. Idempotent; the first close reason wins. *)

val close_with_error : ('a, 'err) t -> 'err -> unit
(** Close the queue with a typed error. Idempotent; the first close reason wins. *)

val stats : ('a, 'err) t -> stats
(** Snapshot queue counters. *)
