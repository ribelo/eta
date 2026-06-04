type operation : immutable_data = [ `Close | `Open | `Read ]

type error_kind : immutable_data =
  [ `Already_exists
  | `File_too_large
  | `Io
  | `Not_found
  | `Not_native
  | `Permission_denied
  | `Unexpected ]

type error : immutable_data = {
  operation : operation;
  path : string;
  kind : error_kind;
  message : string;
  diagnostic : string;
}

val pp_operation : Format.formatter -> operation -> unit
val pp_error_kind : Format.formatter -> error_kind -> unit
val pp_error : Format.formatter -> error -> unit
val make_error : operation:operation -> path:string -> exn -> error
