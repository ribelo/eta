(** HTTP/1.1 chunked transfer coding.

    The decoder is stateful and pull-based. It owns only transfer-coding
    framing; callers own the byte source and map transport failures into the
    eta-http error context. *)

type context = {
  protocol : Eta_http_error.Error.protocol;
  method_ : string;
  uri : string;
}

type reader = {
  read_exact : int -> (bytes, Eta_http_error.Error.t) Eta.Effect.t;
  read_line : limit:int -> (string, Eta_http_error.Error.t) Eta.Effect.t;
}

type t

val default_line_limit : int
val default_max_decoded_bytes : int

val create :
  ?max_decoded_bytes:int ->
  context:context ->
  reader:reader ->
  unit ->
  t

val read : t -> (bytes option, Eta_http_error.Error.t) Eta.Effect.t
val trailers : t -> Eta_http_core.Header.t

val encode_chunk : bytes -> bytes list
val encode_last_chunk : ?trailers:Eta_http_core.Header.t -> unit -> bytes

