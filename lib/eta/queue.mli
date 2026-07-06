(** Same-domain asynchronous queue.

    Queue is an Eta-owned producer/consumer primitive for handoff between
    fibers. It owns two lifecycle modes:

    - [close] and [close_with_error] are graceful fences. Future offers are
      rejected, already buffered values remain drainable, and receivers observe
      the close reason only after the buffer is empty.
    - [shutdown] is an immediate stop. It wakes blocked producers, blocked
      consumers, and [await_shutdown] waiters, drops buffered values, and makes
      future producer/consumer operations report [`Closed].

    Waiter wakeups are post-commit bookkeeping. Once an offer, take, drain,
    close, or shutdown transition has changed queue state, failure while
    resolving another waiter's promise is treated as that waiter's
    cancellation/defect boundary; it does not change the committed result of
    the active operation.

    Create and use each queue on one domain. Queue APIs raise
    [Invalid_argument] when called from a different domain. *)

type ('a, 'err) t
(** Combined producer and consumer queue handle. *)

type ('a, 'err) enqueue
(** Producer-only queue view. *)

type ('a, 'err) dequeue
(** Consumer-only queue view. *)

type stats = {
  capacity : int option;
  depth : int;
  size : int;
  sent : int;
  received : int;
  dropped : int;
  closed : bool;
  shutdown : bool;
  waiting_senders : int;
  waiting_receivers : int;
  cancelled_senders : int;
  cancelled_receivers : int;
}
(** Snapshot queue counters.

    [depth] is the number of buffered values. [size] is logical queue pressure:
    buffered values minus waiting consumers plus waiting backpressured
    producers. It can be negative or greater than [capacity]. *)

type 'err offer_result =
  [ `Sent | `Dropped | `Full | `Closed | `Closed_with_error of 'err ]

type ('a, 'err) poll_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]

type sent_token

val unbounded : unit -> ('a, 'err) t
(** Create an unbounded queue. *)

val bounded : capacity:int -> unit -> ('a, 'err) t
(** Create a bounded backpressured queue.

    Offers wait while the queue is full.

    @raise Invalid_argument if [capacity <= 0]. *)

val dropping : capacity:int -> unit -> ('a, 'err) t
(** Create a bounded dropping queue.

    Offers return [false] or [`Dropped] when the queue is full.

    @raise Invalid_argument if [capacity <= 0]. *)

val sliding : capacity:int -> unit -> ('a, 'err) t
(** Create a bounded sliding queue.

    Offers always admit new values while the queue is open. When the queue is
    full, the oldest buffered values are dropped to make room.

    @raise Invalid_argument if [capacity <= 0]. *)

val enqueue : ('a, 'err) t -> ('a, 'err) enqueue
(** Return a producer-only view. *)

val dequeue : ('a, 'err) t -> ('a, 'err) dequeue
(** Return a consumer-only view. *)

val capacity : ('a, 'err) t -> int option
(** Return [None] for unbounded queues or [Some capacity] for bounded queues. *)

val size : ('a, 'err) t -> int
(** Return logical queue pressure: [depth - waiting_receivers +
    waiting_senders]. *)

val is_empty : ('a, 'err) t -> bool
(** [true] when [size queue <= 0]. *)

val is_full : ('a, 'err) t -> bool
(** [true] when the queue is bounded and [size queue >= capacity]. *)

val is_shutdown : ('a, 'err) t -> bool
(** [true] after [shutdown] has committed. *)

val offer :
  ('a, 'err) t ->
  'a ->
  (bool, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Offer a value and return the admission result.

    [unbounded] and [bounded] queues return [true] once the value is admitted.
    [dropping] queues return [false] when full. [sliding] queues return [true]
    after dropping old buffered values as needed. *)

val offer_all :
  ('a, 'err) t ->
  'a list ->
  ('a list, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Offer values in list order and return values not admitted by policy. *)

val send :
  ('a, 'err) t ->
  'a ->
  (unit, [> `Closed | `Closed_with_error of 'err | `Dropped ]) Effect.t
(** Offer-or-fail helper for callers that do not use admission booleans. *)

val try_offer :
  ('a, 'err) t -> 'a -> ('err offer_result, 'never) Effect.t
(** Try to offer without waiting.

    [bounded] queues return [`Full] instead of waiting when full. *)

val sent_token : ('a, 'err) t -> sent_token
(** Opaque token that changes whenever a value is admitted to the queue. *)

val same_sent_token : sent_token -> sent_token -> bool
(** [same_sent_token a b] is [true] when both tokens represent the same queue
    admission state. *)

val take :
  ('a, 'err) t ->
  ('a, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Take the next value, waiting while the queue is empty. *)

val poll : ('a, 'err) t -> (('a, 'err) poll_result, 'never) Effect.t
(** Try to take one value without waiting. *)

val take_all :
  ('a, 'err) t ->
  ('a list, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Drain all values currently buffered without waiting. *)

val take_up_to :
  ('a, 'err) t ->
  max:int ->
  ('a list, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Drain up to [max] currently buffered values without waiting.

    [max = 0] returns [[]].

    @raise Invalid_argument if [max < 0]. *)

val close : ('a, 'err) t -> unit
(** Close the queue gracefully. Idempotent; the first close reason wins. *)

val close_with_error : ('a, 'err) t -> 'err -> unit
(** Close the queue gracefully with a typed error. Idempotent; the first close
    reason wins. *)

val close_effect : ('a, 'err) t -> (unit, 'never) Effect.t
(** Effectful wrapper for {!close}. *)

val close_with_error_effect :
  ('a, 'err) t -> 'err -> (unit, 'never) Effect.t
(** Effectful wrapper for {!close_with_error}. *)

val shutdown : ('a, 'err) t -> unit
(** Stop the queue immediately and wake blocked operations. Idempotent. *)

val shutdown_effect : ('a, 'err) t -> (unit, 'never) Effect.t
(** Effectful wrapper for {!shutdown}. *)

val await_shutdown : ('a, 'err) t -> (unit, 'never) Effect.t
(** Wait until [shutdown] commits. *)

val stats : ('a, 'err) t -> stats
(** Snapshot queue counters. *)

module Enqueue : sig
  type nonrec ('a, 'err) t = ('a, 'err) enqueue

  val offer :
    ('a, 'err) t ->
    'a ->
    (bool, [> `Closed | `Closed_with_error of 'err ]) Effect.t

  val offer_all :
    ('a, 'err) t ->
    'a list ->
    ('a list, [> `Closed | `Closed_with_error of 'err ]) Effect.t

  val send :
    ('a, 'err) t ->
    'a ->
    (unit, [> `Closed | `Closed_with_error of 'err | `Dropped ]) Effect.t

  val try_offer :
    ('a, 'err) t -> 'a -> ('err offer_result, 'never) Effect.t

  val capacity : ('a, 'err) t -> int option
  val size : ('a, 'err) t -> int
  val is_empty : ('a, 'err) t -> bool
  val is_full : ('a, 'err) t -> bool
  val is_shutdown : ('a, 'err) t -> bool
  val shutdown : ('a, 'err) t -> unit
  val shutdown_effect : ('a, 'err) t -> (unit, 'never) Effect.t
  val await_shutdown : ('a, 'err) t -> (unit, 'never) Effect.t
end

module Dequeue : sig
  type nonrec ('a, 'err) t = ('a, 'err) dequeue

  val take :
    ('a, 'err) t ->
    ('a, [> `Closed | `Closed_with_error of 'err ]) Effect.t

  val poll : ('a, 'err) t -> (('a, 'err) poll_result, 'never) Effect.t

  val take_all :
    ('a, 'err) t ->
    ('a list, [> `Closed | `Closed_with_error of 'err ]) Effect.t

  val take_up_to :
    ('a, 'err) t ->
    max:int ->
    ('a list, [> `Closed | `Closed_with_error of 'err ]) Effect.t

  val capacity : ('a, 'err) t -> int option
  val size : ('a, 'err) t -> int
  val is_empty : ('a, 'err) t -> bool
  val is_full : ('a, 'err) t -> bool
  val is_shutdown : ('a, 'err) t -> bool
  val shutdown : ('a, 'err) t -> unit
  val shutdown_effect : ('a, 'err) t -> (unit, 'never) Effect.t
  val await_shutdown : ('a, 'err) t -> (unit, 'never) Effect.t
end
