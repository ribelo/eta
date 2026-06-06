(** Redaction policy for HTTP diagnostic output. *)

type t = { redacted_headers : string list } [@@unboxed]
(** Header names are matched case-insensitively after trimming. *)

val default : t

val normalize : string -> string
(** Normalize a header name for matching. *)

val is_sensitive : ?policy:t -> string -> bool
(** [is_sensitive name] is [true] when [name] must not be rendered. *)

val headers : ?policy:t -> (string * string) list -> (string * string) list
(** Replace sensitive header values with ["<redacted>"]. *)

val uri : string -> string
(** Replace a URL query string with [?<redacted>] while preserving fragments. *)
