(** Same-domain bounded channel.

    Channel is a WAIT/backpressure primitive for Eta programs that need
    bounded send/receive semantics. v1 is deliberately same-domain: it uses
    Eio synchronization internally and must not be used as a portable or
    cross-domain handoff channel.

    The storage is preallocated at creation time. A closed channel wakes blocked
    senders and receivers. Buffered values remain available to receivers after
    close; once the buffer is empty, receiving fails with Closed.

    Ordering: buffered values are received FIFO, and active blocked senders are
    admitted FIFO as capacity opens. Channel does not provide scheduler fairness
    among fibers that are merely racing to call send or recv. *)

type 'a t

type stats = {
  depth : int;
  sent : int;
  received : int;
  closed : bool;
  waiting_senders : int;
  waiting_receivers : int;
  cancelled_senders : int;
}

type send_result = [ `Sent | `Full | `Closed ]
type 'a recv_result = [ `Item of 'a | `Empty | `Closed ]

val create : capacity:int -> unit -> 'a t
(** Create a bounded channel.

    @raise Invalid_argument if capacity <= 0. *)

val send : 'a t -> 'a -> (unit, [> `Closed ]) Effect.t
(** Send a value, waiting while the channel is full.

    Fails with Closed if the channel is closed before the value is admitted. If
    the sending fiber is cancelled while waiting, its waiter slot is removed and
    cancelled_senders is incremented. *)

val recv : 'a t -> ('a, [> `Closed ]) Effect.t
(** Receive a value, waiting while the channel is empty.

    Fails with Closed once the channel is closed and drained. *)

val try_send : 'a t -> 'a -> (send_result, 'err) Effect.t
(** Try to send without waiting. *)

val try_recv : 'a t -> ('a recv_result, 'err) Effect.t
(** Try to receive without waiting. *)

val close : 'a t -> unit
(** Close the channel and wake blocked senders and receivers. Idempotent. *)

val stats : 'a t -> stats
(** Snapshot channel counters. *)
