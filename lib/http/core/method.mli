(** HTTP request methods. *)

type t =
  [ `GET
  | `HEAD
  | `POST
  | `PUT
  | `DELETE
  | `CONNECT
  | `OPTIONS
  | `TRACE
  | `PATCH
  | `Other of string ]

val of_string : string -> t
val to_string : t -> string
val pp : Format.formatter -> t -> unit
val is_idempotent : t -> bool
