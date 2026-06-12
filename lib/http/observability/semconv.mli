(** OpenTelemetry HTTP client semantic-convention attributes.

    Attribute names follow OpenTelemetry semantic conventions 1.27.0 for HTTP
    client spans. *)

val request_attrs :
  ?emit_url_full:bool ->
  protocol:Client.protocol ->
  Request.t ->
  (string * string) list
(** Request span attributes. By default [url.full] redacts query strings and
    fragments; pass [emit_url_full=true] only when traces are trusted to carry
    raw URLs. *)

val response_attrs : Response.t -> (string * string) list
val error_attrs : Error.t -> (string * string) list
val retry_attrs : attempt:int -> (string * string) list
val redirect_attrs :
  ?emit_location_full:bool -> location:string -> unit -> (string * string) list
(** Redirect response attributes. By default [Location] redacts query strings
    and fragments; pass [emit_location_full=true] only for trusted traces. *)
