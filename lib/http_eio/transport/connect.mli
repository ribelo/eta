(** DNS and TCP/TLS connection helpers for eta-http. *)

type target = {
  url : Url.t;
  scheme : Url.scheme;
  host : string;
  port : int;
  service : string;
}

type tcp_flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

module type EIO_NET = Eta_eio.Host.NET
(** Minimal host module shape needed by eta-http transport hooks. *)

val target_of_url : Url.t -> target

val resolve_stream :
  ?host_eio:Eta_eio.Host.t ->
  net:_ Eio.Net.t ->
  method_:string ->
  target ->
  (Eio.Net.Sockaddr.stream list, Error.t) Eta.Effect.t
(** Resolve stream socket addresses for [target] using [Eio.Net.getaddrinfo_stream].

    Empty results and non-cancellation resolver exceptions are reported as
    typed {!Error.Dns_error} failures. Eio cancellation propagates. *)

val connect_tcp :
  ?host_eio:Eta_eio.Host.t ->
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  method_:string ->
  target ->
  (tcp_flow, Error.t) Eta.Effect.t
(** Resolve [target], then connect to the first stream address that succeeds.

    Resolver failures are {!Error.Dns_error}; failed connection attempts are
    collapsed into {!Error.Connect_error}. Eio cancellation propagates. *)

val connect_tls :
  ?host_eio:Eta_eio.Host.t ->
  ?alpn_protocols:string list ->
  ?ca_file:string ->
  method_:string ->
  target ->
  tcp_flow ->
  (tcp_flow * string option, Error.t) Eta.Effect.t
(** Wrap a TCP flow in the ADR 0002 TLS client policy.

    [ca_file] adds a PEM CA bundle on top of the system trust store.
    Returns the TLS-wrapped flow and the negotiated ALPN protocol.
    Non-cancellation TLS failures are reported as
    {!Error.Tls_handshake_error}. Eio cancellation propagates. *)
