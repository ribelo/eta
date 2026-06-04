(** HTTP/1.1 chunked transfer coding.

    The decoder is stateful and pull-based. It owns only transfer-coding
    framing; callers own the byte source and map transport failures into the
    eta-http error context. *)

type context = {
  protocol : Error.protocol;
  method_ : string;
  uri : string;
}

type reader = {
  read_exact : (int -> (bytes, Error.t) Eta.Effect.t) @@ many;
  read_line : (limit:int -> (string, Error.t) Eta.Effect.t) @@ many;
}

type t

val default_line_limit : int
val default_max_decoded_bytes : int
(** Default maximum decoded bytes for chunked bodies. This matches
    {!Stream.default_max_bytes}. *)

val create :
  ?max_decoded_bytes:int ->
  context:context ->
  reader:reader ->
  unit ->
  t

val read : t -> (bytes option, Error.t) Eta.Effect.t
val trailers : t -> Header.t

val encode_chunk : bytes -> bytes list
val encode_last_chunk : ?trailers:Header.t -> unit -> bytes
