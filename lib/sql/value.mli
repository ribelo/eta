type t =
  | Null
  | Int of int
  | Int64 of int64
  | Float of float
  | String of string
  | Bool of bool
  | Bytes of bytes

val null : t
val int : int -> t
val int64 : int64 -> t
val float : float -> t
val string : string -> t
val bool : bool -> t
val bytes : bytes -> t
val int64_to_int_opt : int64 -> int option
val to_int : t -> int option
val to_int64 : t -> int64 option
val to_float : t -> float option
val to_string_value : t -> string option
val to_bool : t -> bool option
val to_bytes : t -> bytes option
val is_null : t -> bool
val to_string : t -> string
val equal : t -> t -> bool
val compare : t -> t -> int
