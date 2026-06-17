(** Same-domain publish/subscribe hub.

    Pubsub owns a shared hub buffer and scoped subscription lifecycle. Published
    messages are admitted once at the hub, then retained until all current
    subscribers either receive them or unsubscribe. Late subscribers do not
    receive earlier messages.

    v1 is deliberately same-domain, like {!Channel} and {!Queue}. *)

type ('a, 'err) t
type ('a, 'err) subscription

type overflow =
  | Unbounded
  | Drop_new of { capacity : int }
  | Backpressure of { capacity : int }

type publish_result = {
  subscriber_count : int;
  dropped : int;
}

type stats = {
  depth : int;
  subscribers : int;
  published : int;
  received : int;
  dropped : int;
  closed : bool;
  waiting_publishers : int;
  waiting_receivers : int;
  cancelled_publishers : int;
  cancelled_receivers : int;
}

type ('a, 'err) recv_result =
  [ `Item of 'a | `Empty | `Closed | `Closed_with_error of 'err ]

val create : overflow:overflow -> unit -> ('a, 'err) t
(** Create a pubsub hub.

    [Unbounded] has no retained-message limit. [Drop_new] drops a new message
    for all current subscribers when the hub is full. [Backpressure] waits for
    capacity before admitting a new message.

    @raise Invalid_argument if a bounded capacity is <= 0. *)

val publish :
  ('a, 'err) t ->
  'a ->
  (publish_result, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Publish to current subscribers.

    The message is admitted once at the hub. For [Backpressure], cancellation
    while waiting for capacity removes the publisher waiter before admission, so
    subscribers cannot observe a partially published message. *)

val subscribe :
  ('a, 'err) t ->
  (('a, 'err) subscription ->
   ('b, [> `Closed | `Closed_with_error of 'err ] as 'outer) Effect.t) ->
  ('b, 'outer) Effect.t
(** Run [f] with a scoped subscription.

    The subscription is removed when [f] succeeds, fails, or is cancelled. If
    the subscription value escapes, future receives fail with [Closed]. *)

val recv :
  ('a, 'err) subscription ->
  ('a, [> `Closed | `Closed_with_error of 'err ]) Effect.t
(** Receive the next message for a subscription, waiting while no message is
    available and the hub is open.

    Buffered messages remain drainable after close. Once drained, [recv] fails
    with [Closed] or [Closed_with_error err]. *)

val try_recv :
  ('a, 'err) subscription -> (('a, 'err) recv_result, 'never) Effect.t
(** Try to receive without waiting. *)

val close : ('a, 'err) t -> unit
(** Close the hub cleanly. Idempotent; the first close reason wins. Use
    {!close_effect} when the close belongs inside an Eta workflow. *)

val close_with_error : ('a, 'err) t -> 'err -> unit
(** Close the hub with a typed error. Idempotent; the first close reason wins.
    Use {!close_with_error_effect} when the close belongs inside an Eta
    workflow. *)

val close_effect : ('a, 'err) t -> (unit, 'never) Effect.t
(** Effectful wrapper for {!close}. *)

val close_with_error_effect :
  ('a, 'err) t -> 'err -> (unit, 'never) Effect.t
(** Effectful wrapper for {!close_with_error}. *)

val stats : ('a, 'err) t -> stats
(** Snapshot hub counters. *)
