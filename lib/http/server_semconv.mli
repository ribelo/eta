(** OpenTelemetry HTTP server semantic-convention attributes. *)

val request_attrs :
  ?emit_url_full:bool ->
  Server_request.t ->
  (string * string) list

val response_attrs : Server_response.t -> (string * string) list
val error_attrs : Server_error.t -> (string * string) list
