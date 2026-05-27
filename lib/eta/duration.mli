(** Millisecond-precision durations. Same shape as v1 \u2014 pure and small. *)

type t : immutable_data

val zero : t
val ms : int -> t
val seconds : int -> t
val minutes : int -> t
val hours : int -> t
val days : int -> t
val weeks : int -> t
val to_ms : t -> int
val to_seconds_float : t -> float
val is_zero : t -> bool
val add : t -> t -> t
val ( + ) : t -> t -> t
val subtract : t -> t -> t
val times : t -> int -> t
val divide : t -> int -> t option
val min : t -> t -> t
val max : t -> t -> t
val clamp : min:t -> max:t -> t -> t
val between : min:t -> max:t -> t -> bool
val compare : t -> t -> int
val scale : t -> float -> t
val pp : Format.formatter -> t -> unit
val equal : t -> t -> bool
