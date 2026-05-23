(** Retry policy for eta-http requests.

    The default policy retries replayable idempotent requests on transient
    transport failures and on HTTP 408, 429, 502, 503, and 504. POST/PATCH are
    not retried unless the caller supplies an Idempotency-Key header or uses an
    explicit [Always] policy. One-shot bodies are never retried. *)

type mode = Default | Always | Never

type decision =
  | Stop
  | Retry_after of Eta.Duration.t
  | Retry_with_new_connection of Eta.Duration.t

type t

val make :
  ?mode:mode ->
  ?max_attempts:int ->
  ?schedule:Eta.Schedule.t ->
  ?respect_retry_after:bool ->
  unit ->
  t

val default : t
val never : t
val always : ?max_attempts:int -> ?schedule:Eta.Schedule.t -> unit -> t

val retry_after : ?now_s:float -> string -> Eta.Duration.t option

val classify_error :
  t ->
  request:Request.t ->
  attempt:int ->
  Eta_http_error.Error.t ->
  decision

val classify_response :
  t ->
  request:Request.t ->
  attempt:int ->
  Response.t ->
  decision

val run :
  ?policy:t ->
  (Request.t -> (Response.t, Eta_http_error.Error.t) Eta.Effect.t) ->
  Request.t ->
  (Response.t, Eta_http_error.Error.t) Eta.Effect.t
