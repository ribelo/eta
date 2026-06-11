(** Shared eta-http-eio server types. *)

type shutdown =
  | Graceful of Eta.Duration.t
  | Immediate

type domain_policy =
  | Single_domain
  | Recommended
  | Additional of int

module Connection_info : sig
  type t = {
    id : string;
    peer : Eta_http.Server.Request.peer;
    protocol : Eta_http.Server.Error.protocol;
    tls : bool;
    alpn_protocol : string option;
  }
end

type runtime_factory =
  sw:Eio.Switch.t ->
  connection:Connection_info.t ->
  unit ->
  Eta_http.Server.Error.t Eta.Runtime.t

module Config : sig
  type t = {
    max_connections : int;
    backlog : int;
    max_concurrent_streams : int;
    read_buffer_size : int;
    command_queue_capacity : int;
    server : Eta_http.Server.Config.t;
    shutdown : shutdown;
    h2_config : H2.Config.t option;
  }

  val default : t
end

module Stats : sig
  type t = {
    active_connections : int;
    opened_connections : int;
    closed_connections : int;
  }
end
