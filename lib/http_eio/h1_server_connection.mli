(** Eio-owned HTTP/1.x server connection loop. *)

type t

type flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

type time = Server_types.time = {
  sleep : Eta.Duration.t -> unit;
  with_timeout : 'a. Eta.Duration.t -> (unit -> 'a) -> 'a;
}

type stats = Server_stats.H1.snapshot = {
  active_requests : int;
  completed_requests : int;
  request_bytes : int;
  response_bytes : int;
  protocol_errors : int;
}

val run :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Std.r ->
  ?time:time ->
  flow:flow ->
  connection:Server_types.Connection_info.t ->
  config:Server_types.Config.t ->
  runtime_factory:Server_types.runtime_factory ->
  ?on_start:(t -> unit) ->
  ?on_close:(stats -> unit) ->
  Eta_http.Server.handler ->
  unit

val stats : t -> stats
val shutdown : t -> Server_types.shutdown -> unit
