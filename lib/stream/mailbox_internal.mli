type 'a t

type offer_result : immutable_data = Enqueued | Dropped | Closed

type 'a take = Item of 'a | Take_closed

val create : ?capacity:int -> unit -> 'a t
val offer : 'a t -> 'a -> offer_result
val close : 'a t -> unit
val dropped : 'a t -> int
val length : 'a t -> int
val take : 'a t -> 'a take
val take_batch : 'a t -> int -> 'a list take
