type 'a t
type 'a resolver

val create : unit -> 'a t * 'a resolver
val resolve : 'a resolver -> 'a -> unit
val await : 'a t -> scheduler:Scheduler.t -> ('a -> unit) -> unit
val peek : 'a t -> 'a option
