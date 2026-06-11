(** Metrics emitted through the runtime's {!Eta.Capabilities.meter}. *)

val active_connections :
  ?attrs:(string * string) list -> int -> (unit, Server_error.t) Eta.Effect.t

val active_streams :
  ?attrs:(string * string) list -> int -> (unit, Server_error.t) Eta.Effect.t

val requests_total :
  ?attrs:(string * string) list -> int -> (unit, Server_error.t) Eta.Effect.t

val requests_in_flight :
  ?attrs:(string * string) list -> int -> (unit, Server_error.t) Eta.Effect.t

val request_body_bytes :
  ?attrs:(string * string) list -> int -> (unit, Server_error.t) Eta.Effect.t

val response_body_bytes :
  ?attrs:(string * string) list -> int -> (unit, Server_error.t) Eta.Effect.t

val stream_resets :
  ?attrs:(string * string) list -> int -> (unit, Server_error.t) Eta.Effect.t

val protocol_errors :
  ?attrs:(string * string) list -> int -> (unit, Server_error.t) Eta.Effect.t

val shutdown_active :
  ?attrs:(string * string) list -> int -> (unit, Server_error.t) Eta.Effect.t
