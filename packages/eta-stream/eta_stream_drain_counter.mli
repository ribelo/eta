type t

val create : unit -> t
val value : t -> int
val incr : t -> unit
val decr : t -> unit
val incr_by : t -> int -> unit
val decr_by : t -> int -> unit
val await_zero : ?name:string -> t -> (unit, 'err) Eta.Effect.t
