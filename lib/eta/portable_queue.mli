(** Portable bounded MPSC queue for cross-domain data handoff.

    This queue is intended for online producer/consumer transport where many
    workers publish portable values to one coordinator-owned consumer. It is not
    the H3 finite batch inbox: producers and the consumer may overlap. *)

type ('a) t

type push_result =
  | Pushed
  | Full
  | Closed

type 'a take_result =
  | Value of 'a
  | Empty
  | Closed_empty

val create : capacity:int -> 'a t
(** [create ~capacity] creates an open queue with bounded capacity.
    @raise Invalid_argument if [capacity <= 0]. *)

val try_push : 'a t -> 'a -> push_result
(** [try_push queue value] reserves capacity and publishes [value].
    Returns [Full] instead of blocking when the queue is at capacity, and
    [Closed] after {!close}. A push that reserved capacity before a concurrent
    close remains drainable. *)

val try_take : 'a t -> 'a take_result
(** [try_take queue] returns the next value in FIFO order for the single
    consumer, [Empty] when no value is currently available, or [Closed_empty]
    after the queue is closed and fully drained. *)

val close : _ t -> unit
(** [close queue] prevents future reservations. Already pushed values remain
    available to the consumer. *)
