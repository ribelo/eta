(** Eio serving helpers for {!Eta_http_service}. *)

module Serve : sig
  val tcp_addr : host:string -> port:int -> Eio.Net.Sockaddr.stream

  val with_readiness :
    ?ready_path:string option ->
    ready:(unit -> bool) ->
    Eta_http.Server.handler ->
    Eta_http.Server.handler

  val h1 :
    sw:Eio.Switch.t ->
    net:_ Eio.Net.t ->
    clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
    ?time:Eta_http_eio.Server.time ->
    ?domain_manager:_ Eio.Domain_manager.t ->
    ?domain_policy:Eta_http_eio.Server.domain_policy ->
    ?stop:unit Eio.Promise.t ->
    ?config:Eta_http_eio.Server.Config.t ->
    ?runtime_factory:Eta_http_eio.Server.runtime_factory ->
    ?on_error:(exn -> unit) ->
    ?on_connection_close:(Eta_http_eio.H1.Server_connection.stats -> unit) ->
    ?ready_path:string option ->
    ?host:string ->
    ?port:int ->
    ?addr:Eio.Net.Sockaddr.stream ->
    Eta_http.Server.handler ->
    unit

  val h2c :
    sw:Eio.Switch.t ->
    net:_ Eio.Net.t ->
    clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
    ?time:Eta_http_eio.Server.time ->
    ?domain_manager:_ Eio.Domain_manager.t ->
    ?domain_policy:Eta_http_eio.Server.domain_policy ->
    ?stop:unit Eio.Promise.t ->
    ?config:Eta_http_eio.Server.Config.t ->
    ?runtime_factory:Eta_http_eio.Server.runtime_factory ->
    ?on_error:(exn -> unit) ->
    ?on_connection_close:(Eta_http_eio.H2.Server_connection.stats -> unit) ->
    ?ready_path:string option ->
    ?host:string ->
    ?port:int ->
    ?addr:Eio.Net.Sockaddr.stream ->
    Eta_http.Server.handler ->
    unit
end
