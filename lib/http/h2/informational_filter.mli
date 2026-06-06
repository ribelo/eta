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
  (unit, Error.kind) result

val take : t -> string

val forget_stream : t -> int -> unit
(** Forget state associated with a stream that was locally released or reset.
    The filter observes remote END_STREAM/RST frames itself; local teardown must
    call this explicitly because no inbound frame will arrive to clear the
    final-response marker. *)

val buffered_bytes : t -> int

(** [is_passthrough t] is always false. A safe raw passthrough mode would need
    to be stream-specific; callers should continue feeding server-to-client
    bytes through the filter. *)
val is_passthrough : t -> bool
