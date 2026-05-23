(** Metrics emitted through the runtime's {!Eta.Capabilities.meter}. *)

val record_client_stats :
  ?attrs:(string * string) list ->
  Eta_http_client.Client.t ->
  (unit, Eta_http_error.Error.t) Eta.Effect.t
