(** HTTP/1.1 request serialization. *)

type body = Empty | Fixed of bytes list

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
  ?framing_body_length:int ->
  Buffer.t ->
  method_:string ->
  url:Url.t ->
  headers:Header.t ->
  body:body ->
  (unit, Error.t) result
(** Append one HTTP/1.1 request to [Buffer.t].

    The request target is origin-form. [Host] is added when the caller did not
    provide one. Fixed bodies get a [Content-Length] header when absent.
    Caller-provided headers are validated before any bytes are appended.
    [framing_body_length] overrides body length validation only when [body] is
    [Empty], for callers that write headers separately from a streamed body. *)

val to_string :
  method_:string ->
  url:Url.t ->
  headers:Header.t ->
  body:body ->
  (string, Error.t) result
