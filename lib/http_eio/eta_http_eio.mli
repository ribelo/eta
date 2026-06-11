(** Eio transport adapter for eta-http. *)

module Client = Client
module Server = Server

val runtime_service :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  unit ->
  Eta.Runtime_contract.service
(** Eio HTTP client service for {!Eta_http.Client.make_runtime}. Attach this to
    an {!Eta_eio.Runtime.create} call with [~services]. *)

module Tls : sig
  module Config = Eta_http.Tls.Config
  module Eio = Tls_eio
end

module Transport : sig
  module Alpn = Eta_http.Transport.Alpn
  module Connect = Connect
  module Dispatch = Eta_http.Transport.Dispatch
end

module H1 : sig
  module Client = H1_client
  module Parse = Eta_http.H1.Parse
  module Write = Write
end

module H2 : sig
  module Admission = Eta_http.H2.Admission
  module Connection = Connection
  module Frame = Eta_http.H2.Frame
  module Informational_filter = Eta_http.H2.Informational_filter
  module Multiplexer = Multiplexer
  module Server_connection = H2_server_connection
  module Security = Eta_http.H2.Security
  module Stream_state = Eta_http.H2.Stream_state
  module Writer = Writer
end

module Ws : sig
  module Client = Ws_client
  module Codec = Eta_http.Ws.Codec
end
