(** HTTP header list helpers. *)

type t = (string * string) list

val empty : t
val add : string -> string -> t -> t
val of_list : (string * string) list -> t
val to_list : t -> (string * string) list
val normalize_name : string -> string
val get : string -> t -> string option
val get_all : string -> t -> string list
val remove : string -> t -> t
