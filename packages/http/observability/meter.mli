(** Metrics emitted through the runtime's {!Eta.Capabilities.meter}. *)

val record_client_stats :
  ?attrs:(string * string) list ->
  Http_client.Client.t ->
  (unit, Http_error.Error.t) Eta.Effect.t
