(** Eio transport adapter for eta-http. *)

module Client = Client
module Server = Server
module Server_stats = Server_stats

val runtime_service :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  unit ->
  Eta.Runtime_contract.service
(** Eio HTTP client service for {!Eta_http.Client.make_runtime}. Attach this to
    an {!Eta_eio.Runtime.create} call with [~services]. *)

module Tls : sig
  module Config = Eta_http.Tls.Config
  module Eio = Tls_eio
end

module Transport : sig
  module Alpn = Alpn
  module Alpn_server = Alpn_server
  module Connect = Connect
  module Dispatch = Dispatch
end

module H1 : sig
  module Client = H1_client
  module Parse = Eta_http_h1.Parse
  module Server_connection = H1_server_connection
  module Write = Write
end

module H2 : sig
  module Admission = Eta_http_h2.Admission
  module Connection = Connection
  module Frame = Eta_http_h2.Frame
  module Multiplexer = Multiplexer
  module Server_connection = H2_server_connection
  module Security = Eta_http_h2.Security
  module Stream_state = Eta_http_h2.Stream_state
  module Writer = Writer
end

module Ws : sig
  module Client = Ws_client
  module Codec = Eta_http_ws.Codec
end
