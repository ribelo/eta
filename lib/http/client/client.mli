(** Top-level eta-http client API. *)

type protocol = H1 | H2 | Auto

type stats = {
  protocol : protocol;
  active : int;
  idle : int;
  capacity : int;
  opened : int;
  released : int;
}

type t

val protocol_to_string : protocol -> string
val default_max_response_body_bytes : int
(** Default maximum decoded response-body bytes for fixed-length, chunked, and
    close-delimited HTTP/1.1 responses. *)

val protocol : t -> protocol
val stats : t -> (stats, Error.t) Eta.Effect.t
val shutdown : t -> (unit, Error.t) Eta.Effect.t
val request : t -> Request.t -> (Response.t, Error.t) Eta.Effect.t
val request_with_retry :
  ?policy:Retry.t ->
  t ->
  Request.t ->
  (Response.t, Error.t) Eta.Effect.t

val make_h1 :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?max_response_body_bytes:int ->
  ?ca_file:string ->
  unit ->
  t
(** Build the S1 HTTP/1.1 client path.

    Connections are pooled per origin with {!Eta.Pool}.
    [max_response_body_bytes] caps fixed-length, chunked, and
    close-delimited response bodies. [ca_file] adds a PEM CA bundle to
    the trust store on top of the system roots. *)

val make_h1_direct :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?host_eio:Eta.Host_eio.t ->
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
  Eta.Host_eio.t ->
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  net:_ Eio.Net.t ->
  ?tracer:Eta.Capabilities.tracer ->
  ?sampler:Eta.Sampler.t ->
  ?auto_instrument:bool ->
  ?logger:Eta.Capabilities.logger ->
  ?meter:Eta.Capabilities.meter ->
  ?random:Eta.Capabilities.random ->
  ?island_pool:Eta.Effect.Island.pool ->
  ?blocking_pool:Eta.Effect.Blocking.Pool.t ->
  ?capture_backtrace:bool ->
  ?max_response_body_bytes:int ->
  ?ca_file:string ->
  (t -> ('a, 'err) Eta.Effect.t) ->
  ('a, 'err) Eta.Exit.t
(** Create a host-backed runtime and one-shot HTTP/1.1 client, then run one
    effect to completion.

    This is the compact path for [dune utop] workflows: Exergy code can keep
    accepting a normal {!t}, while the interactive session supplies the host
    Eio modules through {!Eta.Host_eio}. *)

val make :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  ?max_response_body_bytes:int ->
  ?ca_file:string ->
  unit ->
  t
(** Build the S2 ALPN-dispatch client path.

    HTTPS requests negotiate [h2, http/1.1] and dispatch to the h2
    multiplexer or h1 request loop from the same caller API. Plain HTTP uses
    the h1 request loop. [max_response_body_bytes] caps HTTP/1.1 response body
    decoding. [ca_file] adds a PEM CA bundle to the trust store. *)

val make_for_test :
  protocol:protocol ->
  request:(Request.t -> (Response.t, Error.t) Eta.Effect.t) ->
  stats:(unit -> (stats, Error.t) Eta.Effect.t) ->
  shutdown:(unit -> (unit, Error.t) Eta.Effect.t) ->
  t

module For_test : sig
  val dispatch_alpn :
    close:(unit -> (unit, Error.t) Eta.Effect.t) ->
    use_h1:(unit -> ('a, Error.t) Eta.Effect.t) ->
    use_h2:(unit -> ('a, Error.t) Eta.Effect.t) ->
    Request.t ->
    string option ->
    ('a, Error.t) Eta.Effect.t

  val h2_informational_status : int -> bool

  val request_h2_on_connection :
    Connection.t ->
    Request.t ->
    Url.t ->
    (Response.t, Error.t) Eta.Effect.t
end
