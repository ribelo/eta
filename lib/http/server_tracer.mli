(** Tracing wrappers for eta-http server handlers. *)

val request :
  ?enabled:bool ->
  ?emit_url_full:bool ->
  Server_handler.t ->
  Server_request.t ->
  (Server_response.t, Server_error.t) Eta.Effect.t
