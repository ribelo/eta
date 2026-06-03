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
    measurement; use {!write_to_bytes}, {!write}, or {!write_to_flow} when
    typed errors are needed. *)

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

val write_to_flow :
  [> Eio.Flow.sink_ty] Eio.Resource.t ->
  method_:string ->
  url:Url.t ->
  headers:Header.t ->
  body:body ->
  (unit, Error.t) result
(** Write one HTTP/1.1 request directly to a flow sink.

    This avoids allocating a complete request string on the transport path.
    Caller-provided headers are validated before any bytes are emitted. The
    request bytes are written synchronously before the function returns. Flow
    write exceptions other than Eio cancellation are translated to
    [Connection_closed] during the HTTP request instead of escaping. *)

val to_string :
  method_:string ->
  url:Url.t ->
  headers:Header.t ->
  body:body ->
  (string, Error.t) result
