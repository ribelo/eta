(** Byte span inside a parser buffer. *)

type t = {
  off : int;
  len : int;
}

val make : off:int -> len:int -> t
val empty : t
val end_offset : t -> int
