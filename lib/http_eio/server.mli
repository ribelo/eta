(** Eio h2c server adapter for eta-http. *)

type shutdown = Server_types.shutdown =
  | Graceful of Eta.Duration.t
  | Immediate

type domain_policy = Server_types.domain_policy =
  | Single_domain
  | Recommended
  | Additional of int

type runtime_factory = Server_types.runtime_factory

type t

module Connection_info = Server_types.Connection_info
module Config = Server_types.Config
module Stats = Server_types.Stats

val start_h2c :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?domain_manager:_ Eio.Domain_manager.t ->
  ?domain_policy:domain_policy ->
  ?config:Config.t ->
  ?runtime_factory:runtime_factory ->
  ?on_connection_close:(H2_server_connection.stats -> unit) ->
  addr:Eio.Net.Sockaddr.stream ->
  Eta_http.Server.handler ->
  t

val start_h2c_on_socket :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?config:Config.t ->
  ?runtime_factory:runtime_factory ->
  ?on_connection_close:(H2_server_connection.stats -> unit) ->
  socket:_ Eio.Net.listening_socket ->
  Eta_http.Server.handler ->
  t

val run_h2c :
  sw:Eio.Switch.t ->
  net:_ Eio.Net.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?domain_manager:_ Eio.Domain_manager.t ->
  ?domain_policy:domain_policy ->
  ?stop:unit Eio.Promise.t ->
  ?config:Config.t ->
  ?runtime_factory:runtime_factory ->
  ?on_connection_close:(H2_server_connection.stats -> unit) ->
  addr:Eio.Net.Sockaddr.stream ->
  Eta_http.Server.handler ->
  unit

val run_h2c_on_socket :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?stop:unit Eio.Promise.t ->
  ?config:Config.t ->
  ?runtime_factory:runtime_factory ->
  ?on_connection_close:(H2_server_connection.stats -> unit) ->
  socket:_ Eio.Net.listening_socket ->
  Eta_http.Server.handler ->
  unit

val shutdown : t -> shutdown -> unit
val stats : t -> Stats.t
