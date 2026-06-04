(** Negotiated HTTP protocol versions. *)

type t : immutable_data = H1_0 | H1_1 | H2

val to_string : t -> string
val pp : Format.formatter -> t -> unit
