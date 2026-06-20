(** Backend-neutral eta-http client API. *)

type protocol = H1 | H2 | Auto

type stats = {
  protocol : protocol;
  active : int;
  idle : int;
  capacity : int;
  opened : int;
  released : int;
}

type runtime_options = {
  selected_protocol : protocol;
  max_response_body_bytes : int;
  ca_file : string option;
}

type service = {
  request :
    runtime_options -> Request.t -> (Response.t, Error.t) Eta.Effect.t;
  stats : runtime_options -> (stats option, Error.t) Eta.Effect.t;
  shutdown : runtime_options -> (unit, Error.t) Eta.Effect.t;
}

type t

val protocol_to_string : protocol -> string
val default_max_response_body_bytes : int

val protocol : t -> protocol
val stats : t -> (stats option, Error.t) Eta.Effect.t
val shutdown : t -> (unit, Error.t) Eta.Effect.t
val request : t -> Request.t -> (Response.t, Error.t) Eta.Effect.t

val request_with_retry :
  ?policy:Retry.t ->
  t ->
  Request.t ->
  (Response.t, Error.t) Eta.Effect.t

val runtime_service : service -> Eta.Runtime_contract.service
(** Pack an HTTP client service for attachment to an Eta runtime. *)

val make_runtime :
  ?protocol:protocol ->
  ?max_response_body_bytes:int ->
  ?ca_file:string ->
  unit ->
  t
(** Build a client that resolves transport through the current Eta runtime. *)

val make_custom :
  protocol:protocol ->
  request:(Request.t -> (Response.t, Error.t) Eta.Effect.t) ->
  stats:(unit -> (stats option, Error.t) Eta.Effect.t) ->
  shutdown:(unit -> (unit, Error.t) Eta.Effect.t) ->
  t
(** Build a client from custom request, stats, and shutdown handlers. *)
