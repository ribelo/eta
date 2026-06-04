type t : immutable_data =
  | All
  | Trace
  | Debug
  | Info
  | Warn
  | Error
  | Fatal
  | Off

val to_string : t -> string
val of_string : string -> t option
val compare : t -> t -> int
val equal : t -> t -> bool
val is_enabled : at:t -> threshold:t -> bool
val to_otel_severity : t -> int
val of_otel_severity : int -> t
val pp : Format.formatter -> t -> unit
val all : t list
