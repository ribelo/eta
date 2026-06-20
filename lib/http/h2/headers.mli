type t = (string * string) list

val empty : t
val to_list : t -> (string * string) list
val of_list : (string * string) list -> t
val of_rev_list : (string * string) list -> t
val get : t -> string -> string option
val add : t -> string -> string -> t
