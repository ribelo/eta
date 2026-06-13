(** Eio transport adapter for eta-http clients. *)

type protocol = Eta_http.Client.protocol = H1 | H2 | Auto
type stats = Eta_http.Client.stats = {
  protocol : protocol;
  active : int;
  idle : int;
  capacity : int;
  opened : int;
  released : int;
}
type runtime_options = Eta_http.Client.runtime_options = {
  selected_protocol : protocol;
  max_response_body_bytes : int;
  ca_file : string option;
}
type service = Eta_http.Client.service = {
  request :
    runtime_options -> Eta_http.Request.t -> (Eta_http.Response.t, Eta_http.Error.t) Eta.Effect.t;
  stats : runtime_options -> (stats, Eta_http.Error.t) Eta.Effect.t;
  shutdown : runtime_options -> (unit, Eta_http.Error.t) Eta.Effect.t;
}
type t = Eta_http.Client.t

val protocol_to_string : protocol -> string
val default_max_response_body_bytes : int
(** Default maximum decoded response-body bytes for fixed-length, chunked, and
    close-delimited HTTP/1.1 responses. *)

val protocol : t -> protocol
val stats : t -> (stats, Eta_http.Error.t) Eta.Effect.t
val shutdown : t -> (unit, Eta_http.Error.t) Eta.Effect.t
val request : t -> Eta_http.Request.t -> (Eta_http.Response.t, Eta_http.Error.t) Eta.Effect.t
val request_with_retry :
  ?policy:Eta_http.Retry_policy.t ->
  t ->
  Eta_http.Request.t ->
  (Eta_http.Response.t, Eta_http.Error.t) Eta.Effect.t

val runtime_service : service -> Eta.Runtime_contract.service

val make_h1 :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?max_response_body_bytes:int ->
  ?ca_file:string ->
  unit ->
  t
(** Build the pooled HTTP/1.1 client path.

    Connections are pooled per origin with {!Eta.Pool}.
    [max_response_body_bytes] caps fixed-length, chunked, and
    close-delimited response bodies. [ca_file] adds a PEM CA bundle to
    the trust store on top of the system roots. *)

val make_h1_direct :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?host_eio:Eta_eio.Host.t ->
  ?max_response_body_bytes:int ->
  ?ca_file:string ->
  unit ->
  t
(** Build a one-shot HTTP/1.1 client path.

    Each request opens a connection, executes one request, and closes the flow
    when the response body is consumed or discarded. This path is useful for
    REPL helpers because it avoids the pooled client's background ownership
    fibers. *)

val run_host_h1 :
  Eta_eio.Host.t ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  net:_ Eio.Net.t ->
  ?tracer:Eta.Capabilities.tracer ->
  ?sampler:Eta.Sampler.t ->
  ?auto_instrument:bool ->
  ?logger:Eta.Capabilities.logger ->
  ?meter:Eta.Capabilities.meter ->
  ?random:Eta.Capabilities.random ->
  ?blocking_pool:Eta_blocking.Pool.t ->
  ?capture_backtrace:bool ->
  ?max_response_body_bytes:int ->
  ?ca_file:string ->
  (t -> ('a, 'err) Eta.Effect.t) ->
  ('a, 'err) Eta.Exit.t
(** Create a host-backed runtime and one-shot HTTP/1.1 client, then run one
    eff to completion.

    This is the compact path for [dune utop] workflows: Exergy code can keep
    accepting a normal {!t}, while the interactive session supplies the host
    Eio modules through {!Eta_eio.Host}. *)

val make :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?max_response_body_bytes:int ->
  ?ca_file:string ->
  unit ->
  t
(** Build the S2 ALPN-dispatch client path.

    HTTPS requests negotiate [h2, http/1.1] and dispatch to the h2
    multiplexer or h1 request loop from the same caller API. Plain HTTP uses
    the h1 request loop. [max_response_body_bytes] caps HTTP/1.1 response body
    decoding. [ca_file] adds a PEM CA bundle to the trust store. *)

val request_h2_on_connection :
  Connection.t ->
  Eta_http.Request.t ->
  Url.t ->
  (Eta_http.Response.t, Eta_http.Error.t) Eta.Effect.t
(** Submit one eta-http request on an already-owned HTTP/2 connection. Advanced
    callers that manage HTTP/2 connection ownership directly can use this
    instead of the pooled ALPN client. *)
