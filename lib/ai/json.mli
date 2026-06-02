type t = Yojson.Safe.t

val parse : string -> (t, string) result
val to_string : t -> string
val compact : t -> string
val string : string -> t
val bool : bool -> t
val int : int -> t
val float : float -> t option
val array : t list -> t
val object_ : (string * t option) list -> t
val member : string -> t -> t option
val string_member : string -> t -> string option
val scalar_string_member : string -> t -> string option
val int_member : string -> t -> int option
val array_member : string -> t -> t list option
val object_member : string -> t -> t option
