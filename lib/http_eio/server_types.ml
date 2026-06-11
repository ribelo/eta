(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type shutdown =
  | Graceful of Eta.Duration.t
  | Immediate

type domain_policy =
  | Single_domain
  | Recommended
  | Additional of int

module Connection_info = struct
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

module Config = struct
  type t = {
    max_connections : int;
    backlog : int;
    max_concurrent_streams : int;
    read_buffer_size : int;
    command_queue_capacity : int;
    tls_handshake_timeout : Eta.Duration.t;
    server : Eta_http.Server.Config.t;
    shutdown : shutdown;
    h2_config : H2.Config.t option;
    h2_security_config : Eta_http.H2.Security.config option;
  }

  let default =
    {
      max_connections = 1024;
      backlog = 128;
      max_concurrent_streams = 128;
      read_buffer_size = 64 * 1024;
      command_queue_capacity = 1024;
      tls_handshake_timeout = Eta.Duration.seconds 10;
      server = Eta_http.Server.Config.default;
      shutdown = Graceful (Eta.Duration.seconds 30);
      h2_config = None;
      h2_security_config = None;
    }
end

module Stats = struct
  type t = Server_stats.Listener.snapshot = {
    active_connections : int;
    opened_connections : int;
    closed_connections : int;
    tls_handshakes : int;
    tls_handshake_failures : int;
    alpn_h1 : int;
    alpn_h2 : int;
    alpn_rejected : int;
  }
end
