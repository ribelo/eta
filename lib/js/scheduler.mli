type t
type priority = int

val create : ?max_ops_before_yield:int -> unit -> t
val enqueue : t -> ?priority:priority -> (unit -> unit) -> unit
val drain_ready : t -> unit
val ready_count : t -> int
val should_yield : t -> op_count:int -> bool
