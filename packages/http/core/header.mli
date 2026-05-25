(** HTTP header list helpers.

    Header names accepted by validated constructors are RFC token strings.
    Header values permit HTAB and reject CR, LF, NUL, and other control bytes
    so callers cannot inject additional wire header lines through serialized
    requests. *)

type t = (string * string) list
type name = private string
type value = private string

val empty : t
val name : string -> (name, Http_error.Error.kind) result
val value : string -> (value, Http_error.Error.kind) result
val pair : string -> string -> (name * value, Http_error.Error.kind) result
val add : string -> string -> t -> (t, Http_error.Error.kind) result
val of_list : (string * string) list -> (t, Http_error.Error.kind) result
val unsafe_add : string -> string -> t -> t
val unsafe_of_list : (string * string) list -> t
val to_list : t -> (string * string) list
val normalize_name : string -> string
val validate_name : string -> Http_error.Error.kind option
val validate_value : string -> Http_error.Error.kind option
val validate_header : string * string -> Http_error.Error.kind option
val validate : t -> Http_error.Error.kind option
val[@zero_alloc] valid : t -> bool
val get : string -> t -> string option
val get_all : string -> t -> string list
val remove : string -> t -> t
