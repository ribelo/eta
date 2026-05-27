(** Metrics emitted through the runtime's {!Eta.Capabilities.meter}. *)

val record_client_stats :
  ?attrs:(string * string) list ->
  Client.t ->
  (unit, Error.t) Eta.Effect.t
