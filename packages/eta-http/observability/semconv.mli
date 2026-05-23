(** OpenTelemetry HTTP client semantic-convention attributes.

    Attribute names follow OpenTelemetry semantic conventions 1.27.0 for HTTP
    client spans. *)

val request_attrs :
  protocol:Eta_http_client.Client.protocol ->
  Eta_http_client.Request.t ->
  (string * string) list

val response_attrs : Eta_http_client.Response.t -> (string * string) list
val error_attrs : Eta_http_error.Error.t -> (string * string) list
val retry_attrs : attempt:int -> (string * string) list
val redirect_attrs : location:string -> (string * string) list
