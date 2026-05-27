(** RFC 3986 client-subset URLs.

    The parser accepts absolute [http] and [https] URLs with authority, optional
    port, path, query, and fragment. It rejects userinfo and unsupported
    schemes because eta-http v1 does not own authentication policy. *)

type t

type scheme = Eta_http | Https

type parse_error =
  | Empty
  | Missing_scheme
  | Unsupported_scheme of string
  | Missing_authority
  | Missing_host
  | Userinfo_not_supported
  | Invalid_port of string
  | Invalid_character of {
      component : string;
      index : int;
      char : char;
    }

val parse : string -> (t, parse_error) result
val of_string : string -> t
(** Parse a URL or raise [Invalid_argument]. Prefer {!parse} at API boundaries. *)

val pp_parse_error : Format.formatter -> parse_error -> unit
val parse_error_to_string : parse_error -> string

val to_string : t -> string
val scheme : t -> scheme
val scheme_to_string : scheme -> string
val host : t -> string
(** Host without URI brackets. IPv6 literals such as [https://[::1]/] return
    ["::1"] so transport peer-identity checks can parse the IP literal. *)
val port : t -> int option
val default_port : scheme -> int
val effective_port : t -> int
val path : t -> string
val query : t -> string option
val fragment : t -> string option
val authority : t -> string
(** Host plus optional port for HTTP authority and Host headers. IPv6 literals
    include URI brackets, for example ["[::1]:8443"]. *)
val origin_form : t -> string
val blit_authority : bytes -> pos:int -> t -> int
(** Write the URL authority into [bytes] at [pos]. Returns the next offset, or
    a negative value if [bytes] is too small. *)

val[@zero_alloc] blit_authority_raw : bytes -> int -> t -> int

val blit_origin_form : bytes -> pos:int -> t -> int
(** Write the origin-form request target into [bytes] at [pos]. Returns the
    next offset, or a negative value if [bytes] is too small. *)

val[@zero_alloc] blit_origin_form_raw : bytes -> int -> t -> int

val redacted : t -> string
