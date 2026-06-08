type 'a t

val create : int -> 'a t
val add : 'a t -> scheduler:Scheduler.t -> 'a -> unit
val take : 'a t -> scheduler:Scheduler.t -> ('a -> unit) -> unit
val take_nonblocking : 'a t -> 'a option
val length : 'a t -> int
val taker_count : 'a t -> int
