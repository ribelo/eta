(** Same-runtime publish/subscribe hub for eta_js fibers. *)

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

val publish :
  ('a, 'err) t ->
  'a ->
  (publish_result, [> `Closed | `Closed_with_error of 'err ]) Effect.t

val subscribe :
  ('a, 'err) t ->
  (('a, 'err) subscription ->
   ('b, [> `Closed | `Closed_with_error of 'err ] as 'outer) Effect.t) ->
  ('b, 'outer) Effect.t

val recv :
  ('a, 'err) subscription ->
  ('a, [> `Closed | `Closed_with_error of 'err ]) Effect.t

val try_recv : ('a, 'err) subscription -> (('a, 'err) recv_result, 'never) Effect.t
val close : ('a, 'err) t -> unit
val close_with_error : ('a, 'err) t -> 'err -> unit
val stats : ('a, 'err) t -> stats
