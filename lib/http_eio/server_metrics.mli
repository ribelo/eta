(** Runtime-backed HTTP server metric emission. *)

type t

val connection :
  runtime:Eta_http.Server.Error.t Eta.Runtime.t ->
  connection:Server_types.Connection_info.t ->
  t

val request :
  runtime:Eta_http.Server.Error.t Eta.Runtime.t ->
  connection:Server_types.Connection_info.t ->
  emit_url_full:bool ->
  Eta_http.Server.Request.t ->
  t

val active_connections : t -> int -> unit
val active_streams : t -> int -> unit
val requests_in_flight : t -> int -> unit
val requests_total : t -> int -> unit
val request_body_bytes : t -> int -> unit
val response_body_bytes : t -> int -> unit
val stream_resets : t -> int -> unit
val protocol_errors : t -> int -> unit
val shutdown_active : t -> int -> unit

val request_started : t -> unit
val request_finished : t -> unit
val stream_started : t -> unit
val stream_finished : t -> unit
