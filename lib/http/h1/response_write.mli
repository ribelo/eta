(** HTTP/1.x server response serialization decisions. *)

type body =
  | No_body
  | Fixed of bytes list
  | Stream_fixed of Server_response.Body.stream
  | Stream_chunked of Server_response.Body.stream
  | Stream_close_delimited of Server_response.Body.stream

type prepared = {
  head : string;
  body : body;
  close : bool;
}

type error =
  | Caller_framing_header of string
  | Body_length_overflow
  | Streaming_body

val pp_error : Format.formatter -> error -> unit
val error_to_string : error -> string

val prepare :
  ?connection_close:bool ->
  version:Version.t ->
  request_method:string ->
  Server_response.t ->
  (prepared, error) result

val to_string :
  ?connection_close:bool ->
  version:Version.t ->
  request_method:string ->
  Server_response.t ->
  (string, error) result
(** Serialize non-streaming responses. Streaming responses return
    [Streaming_body]; callers should use {!prepare} and write the stream
    according to the returned [body] framing. *)

val encode_chunk : bytes -> bytes list
val encode_last_chunk : ?trailers:Header.t -> unit -> bytes
