(** Retry policy for eta-http requests.

    The default policy retries replayable idempotent requests on transient
    transport failures and on HTTP 408, 429, 502, 503, and 504. POST/PATCH are
    not retried unless the caller supplies an Idempotency-Key header or uses an
    explicit [Always] policy. One-shot bodies are never retried.

    [retry_status] customizes which HTTP response statuses are retried. This is
    useful for protocols layered on HTTP whose retry table is stricter than the
    eta-http default, for example OTLP/HTTP. *)

type mode = Default | Always | Never

type decision =
  | Stop
  | Retry_after of Eta.Duration.t

type t

val default_retry_status : int -> bool
val default_max_retry_after : Eta.Duration.t

val make :
  ?mode:mode ->
  ?max_attempts:int ->
  ?schedule:(unit, 'schedule_out, Eta.Schedule.no_hook) Eta.Schedule.t ->
  ?respect_retry_after:bool ->
  ?max_retry_after:Eta.Duration.t ->
  ?retry_status:(int -> bool) ->
  unit ->
  t
(** [make ~max_attempts ()] raises [Invalid_argument] when [max_attempts] is
    less than 1.

    [max_retry_after] caps peer-controlled Retry-After delays. The default is
    {!default_max_retry_after}. *)

val default : t
val never : t
val always :
  ?max_attempts:int ->
  ?schedule:(unit, 'schedule_out, Eta.Schedule.no_hook) Eta.Schedule.t ->
  ?retry_status:(int -> bool) ->
  unit ->
  t

val retry_after :
  ?max_delay:Eta.Duration.t -> ?now_s:float -> string -> Eta.Duration.t option

val classify_error :
  ?now_s:float ->
  t ->
  request:Request.t ->
  attempt:int ->
  Error.t ->
  decision

val classify_response :
  ?now_s:float ->
  t ->
  request:Request.t ->
  attempt:int ->
  Response.t ->
  decision

val run :
  ?policy:t ->
  ?now_s:(unit -> float) ->
  (Request.t -> (Response.t, Error.t) Eta.Effect.t) ->
  Request.t ->
  (Response.t, Error.t) Eta.Effect.t
