(** HTTP response status helpers. *)

type t = int

val of_int : int -> t option
val unsafe_of_int : int -> t
val to_int : t -> int
val class_ : t -> string
val is_informational : t -> bool
val is_success : t -> bool
val is_redirection : t -> bool
val is_client_error : t -> bool
val is_server_error : t -> bool
