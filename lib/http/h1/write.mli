(** HTTP/1.1 request serialization. *)

type body = Empty | Fixed of bytes list

type stream_framing = Fixed_length of int | Chunked

val content_length : body -> int option

val write_to_bytes_raw :
  bytes ->
  pos:int ->
  method_:string ->
  url:Url.t ->
  headers:Header.t ->
  body:body ->
  int
(** Low-level writer core for allocation probes.

    Returns the next offset on success. Negative values are internal error
    codes. This function is intended for bounded probes and hot-path
    measurement; use {!write_to_bytes} or {!write} when typed errors are
    needed. *)

val write_to_bytes :
  bytes ->
  pos:int ->
  method_:string ->
  url:Url.t ->
  headers:Header.t ->
  body:body ->
  (int, Error.t) result
(** Write one HTTP/1.1 request into a caller-owned byte buffer.

    Caller-provided headers are validated before any bytes are written. *)

val write :
  Buffer.t ->
  method_:string ->
  url:Url.t ->
  headers:Header.t ->
  body:body ->
  (unit, Error.t) result
(** Append one HTTP/1.1 request to [Buffer.t].

    The request target is origin-form. [Host] is added when the caller did not
    provide one. Fixed bodies get a [Content-Length] header when absent.
    Caller-provided headers are validated before any bytes are appended. *)

val write_stream_headers :
  Buffer.t ->
  method_:string ->
  url:Url.t ->
  headers:Header.t ->
  framing:stream_framing ->
  (unit, Error.t) result
(** Append one HTTP/1.1 request head for a separately written stream body.

    The streaming writer owns framing: [Fixed_length] writes or validates
    [Content-Length], while [Chunked] writes [Transfer-Encoding: chunked].
    Caller-provided [Transfer-Encoding] is rejected. *)

val to_string :
  method_:string ->
  url:Url.t ->
  headers:Header.t ->
  body:body ->
  (string, Error.t) result
