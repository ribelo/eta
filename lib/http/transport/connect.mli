(** DNS and TCP/TLS connection helpers for eta-http. *)

type target = {
  url : Eta_http_core.Url.t;
  scheme : Eta_http_core.Url.scheme;
  host : string;
  port : int;
  service : string;
}

type tcp_flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

val target_of_url : Eta_http_core.Url.t -> target

val resolve_stream :
  net:_ Eio.Net.t ->
  method_:string ->
  target ->
  (Eio.Net.Sockaddr.stream list, Eta_http_error.Error.t) Eta.Effect.t
(** Resolve stream socket addresses for [target] using [Eio.Net.getaddrinfo_stream].

    Empty results and resolver exceptions are reported as typed
    {!Eta_http_error.Error.Dns_error} failures. *)

val connect_tcp :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  method_:string ->
  target ->
  (tcp_flow, Eta_http_error.Error.t) Eta.Effect.t
(** Resolve [target], then connect to the first stream address that succeeds.

    Resolver failures are {!Eta_http_error.Error.Dns_error}; failed connection
    attempts are collapsed into {!Eta_http_error.Error.Connect_error}. *)

val connect_tls :
  ?alpn_protocols:string list ->
  ?ca_file:string ->
  method_:string ->
  target ->
  tcp_flow ->
  (tcp_flow * string option, Eta_http_error.Error.t) Eta.Effect.t
(** Wrap a TCP flow in the ADR 0002 TLS client policy.

    [ca_file] adds a PEM CA bundle on top of the system trust store.
    Returns the TLS-wrapped flow and the negotiated ALPN protocol.
    TLS failures are reported as
    {!Eta_http_error.Error.Tls_handshake_error}. *)
