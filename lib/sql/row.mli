type t = (string * Value.t) list

val get : string -> t -> Value.t option
val fields : t -> string list
val int : string -> t -> int option
val int64 : string -> t -> int64 option
val string : string -> t -> string option
val bool : string -> t -> bool option
val float : string -> t -> float option
val bytes : string -> t -> bytes option
val to_string : t -> string
val equal : t -> t -> bool

