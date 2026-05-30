type operation = [ `Close | `Open | `Read ]

type error_kind =
  [ `Already_exists
  | `File_too_large
  | `Io
  | `Not_found
  | `Not_native
  | `Permission_denied
  | `Unexpected ]

type error = {
  operation : operation;
  path : string;
  kind : error_kind;
  message : string;
  cause : exn;
}

let pp_operation ppf = function
  | `Open -> Format.pp_print_string ppf "open"
  | `Read -> Format.pp_print_string ppf "read"
  | `Close -> Format.pp_print_string ppf "close"

let pp_error_kind ppf = function
  | `Already_exists -> Format.pp_print_string ppf "already_exists"
  | `File_too_large -> Format.pp_print_string ppf "file_too_large"
  | `Io -> Format.pp_print_string ppf "io"
  | `Not_found -> Format.pp_print_string ppf "not_found"
  | `Not_native -> Format.pp_print_string ppf "not_native"
  | `Permission_denied -> Format.pp_print_string ppf "permission_denied"
  | `Unexpected -> Format.pp_print_string ppf "unexpected"

let pp_error ppf error =
  Format.fprintf ppf "%a %s failed (%a): %s" pp_operation error.operation
    error.path pp_error_kind error.kind error.message

let kind_of_exn = function
  | Eio.Io (Eio.Fs.E (Eio.Fs.Already_exists _), _) -> `Already_exists
  | Eio.Io (Eio.Fs.E Eio.Fs.File_too_large, _) -> `File_too_large
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_found _), _) -> `Not_found
  | Eio.Io (Eio.Fs.E (Eio.Fs.Not_native _), _) -> `Not_native
  | Eio.Io (Eio.Fs.E (Eio.Fs.Permission_denied _), _) -> `Permission_denied
  | Eio.Io _ -> `Io
  | _ -> `Unexpected

let make_error ~operation ~path cause =
  {
    operation;
    path;
    kind = kind_of_exn cause;
    message = Format.asprintf "%a" Eio.Exn.pp cause;
    cause;
  }
