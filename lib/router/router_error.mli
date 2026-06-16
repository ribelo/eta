(** Error taxonomy for the router. *)

type insert =
  | Conflict of string
      (** Another route already occupies the requested path. *)
  | Invalid_route of string
      (** The route string is malformed or contains ambiguous parameters. *)

type match_ = Not_found  (** No registered route matches the requested path. *)

type merge = Conflicts of insert list
  (** A merge produced one or more insertion conflicts. *)
