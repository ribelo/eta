(** Input filter for HTTP/2 informational response headers.

    ocaml-h2 0.13 treats the first response HEADERS as the active response,
    including 1xx interim responses. This filter sits before ocaml-h2's client
    parser, consumes server HEADERS/CONTINUATION blocks, drops interim 1xx
    blocks, and re-encodes final response/trailer blocks so ocaml-h2's HPACK
    decoder sees a coherent stream. *)

type t

val create : unit -> t

val feed :
  t ->
  string ->
  off:int ->
  len:int ->
  (unit, Eta_http_error.Error.kind) result

val take : t -> string

val buffered_bytes : t -> int
