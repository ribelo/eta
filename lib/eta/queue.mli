(** Same-domain queue.

    Queue is an Eta-owned producer/consumer primitive for handoff between
    fibers. It owns the close fence: after [close] or [close_with_error], future
    offers are rejected and already buffered values remain drainable before
    receivers observe the close reason.

    Waiter wakeups are post-commit bookkeeping. Once a send, receive, drain,
    or close transition has changed queue state, failure while resolving another
    waiter's promise is treated as that waiter's cancellation/defect boundary;
    it does not change the committed result of the active operation. Runtime
    adapters are expected to make promise resolution either notify the waiter
    or fail only when that waiter is no longer able to observe the notification.

    Create and use each queue on one domain. Queue APIs raise
    [Invalid_argument] when called from a different domain. *)

type ('a, 'err) t

type overflow =
  | Unbounded
  | Drop_new of { capacity : int }
  | Backpressure of { capacity : int }

type stats = {
  depth : int;
  sent : int;
  received : int;
  dropped : int;
  closed : bool;
  waiting_senders : int;
  waiting_receivers : int;
  cancelled_senders : int;
  cancelled_receivers : int;
}

type 'err send_result =
  [ `Sent | `Dropped | `Full | `Closed | `Closed_with_error of 'err ]
type ('a, 'err) recv_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]
type sent_token

val create : ?overflow:overflow -> unit -> ('a, 'err) t
(** Create a queue.

    [Unbounded] has no capacity limit. [Drop_new] drops a new value when the
    queue is full and reports that as an admission result. [Backpressure] waits
    for capacity before admitting a new value.

    [overflow] defaults to [Unbounded].

    @raise Invalid_argument if a bounded capacity is <= 0. *)

val unbounded : unit -> ('a, 'err) t
(** Alias for [create ~overflow:Unbounded]. *)

val offer :
  ('a, 'err) t ->
  'a ->
  (bool, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Offer a value and return the admission result.

    [Unbounded] admits immediately. [Drop_new] returns [false] when the queue
    is full. [Backpressure] waits until the value is admitted or the queue is
    closed. Cancellation while still waiting removes the sender waiter. If
    cancellation races with admission or queue close, the committed admission or
    close result wins. *)

val offer_all :
  ('a, 'err) t ->
  'a list ->
  ('a list, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Offer values in list order and return values not admitted by policy.

    An empty returned list means all values were admitted. [Drop_new] queues
    return the dropped values. [Backpressure] queues wait for capacity and
    return [] unless the offer is cancelled or the queue closes. *)

val send :
  ('a, 'err) t ->
  'a ->
  (unit, [> `Closed | `Closed_with_error of 'err | `Dropped ]) Effect.t
(** Enqueue-or-fail helper for callers that do not need admission details.

    [Drop_new] queues fail with [`Dropped] when the value is rejected by
    policy. Use {!offer} when rejection is expected control flow and should be
    handled as [false] instead of as a typed failure. *)

val recv :
  ('a, 'err) t ->
  ('a, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Receive the next value, waiting while the queue is empty.

    Buffered values are delivered after close. Once the buffer is drained,
    [close] fails with [`Closed] and [close_with_error err] fails with
    [`Closed_with_error err]. *)

val try_send : ('a, 'err) t -> 'a -> ('err send_result, 'never) Effect.t
(** Try to enqueue without waiting.

    [Backpressure] queues return [`Full] instead of waiting when full.
    [Drop_new] queues return [`Dropped] when full. Unbounded queues never return
    [`Full] or [`Dropped]. *)

val sent_token : ('a, 'err) t -> sent_token
(** Opaque token that changes whenever a value is admitted to the queue. Unlike
    {!stats}, this token is not a saturating counter and is suitable for
    cancellation-safe publication bookkeeping. *)

val same_sent_token : sent_token -> sent_token -> bool
(** [same_sent_token a b] is [true] when both tokens represent the same queue
    admission state. *)

val try_recv : ('a, 'err) t -> (('a, 'err) recv_result, 'never) Effect.t
(** Try to receive without waiting. *)

val take_all :
  ('a, 'err) t ->
  ('a list, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Drain all values currently buffered.

    Returns [[]] when the queue is open and empty. If the queue is closed and
    empty, fails with the close reason. *)

val take_batch :
  ('a, 'err) t ->
  max:int ->
  ('a list, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Drain up to [max] currently buffered values.

    Returns [[]] when the queue is open and empty. If the queue is closed and
    empty, fails with the close reason.

    @raise Invalid_argument if [max <= 0]. *)

val close : ('a, 'err) t -> unit
(** Close the queue cleanly. Idempotent; the first close reason wins. Use
    {!close_effect} when the close belongs inside an Eta workflow. *)

val close_with_error : ('a, 'err) t -> 'err -> unit
(** Close the queue with a typed error. Idempotent; the first close reason wins.
    Use {!close_with_error_effect} when the close belongs inside an Eta
    workflow. *)

val close_effect : ('a, 'err) t -> (unit, 'never) Effect.t
(** Effectful wrapper for {!close}. *)

val close_with_error_effect :
  ('a, 'err) t -> 'err -> (unit, 'never) Effect.t
(** Effectful wrapper for {!close_with_error}. *)

val stats : ('a, 'err) t -> stats
(** Snapshot queue counters. *)
