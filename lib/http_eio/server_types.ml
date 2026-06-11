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
    read_buffer_size : int;
    command_queue_capacity : int;
    tls_handshake_timeout : Eta.Duration.t;
    server : Eta_http.Server.Config.t;
    h2_config : H2.Config.t;
    h2_security_config : Eta_http.H2.Security.config option;
  }

  let default =
    {
      max_connections = 1024;
      backlog = 128;
      read_buffer_size = 64 * 1024;
      command_queue_capacity = 1024;
      tls_handshake_timeout = Eta.Duration.seconds 10;
      server = Eta_http.Server.Config.default;
      h2_config = { H2.Config.default with max_concurrent_streams = 128l };
      h2_security_config = None;
    }

  let field name = "Eta_http_eio.Server.Config." ^ name

  let require_positive name value =
    if value <= 0 then invalid_arg (field name ^ " must be > 0")

  let require_positive_duration name value =
    if Eta.Duration.is_zero value then
      invalid_arg (field name ^ " must be > 0")

  let require_positive_int32 name value =
    if Int32.compare value 0l <= 0 then
      invalid_arg (field name ^ " must be > 0")

  let require_non_negative_int32 name value =
    if Int32.compare value 0l < 0 then
      invalid_arg (field name ^ " must be >= 0")

  let validate_h2_frame_size name value =
    if value < 0x4000 || value > 0xffffff then
      invalid_arg (field name ^ " must be between 16384 and 16777215")

  let validate_h2_config (config : H2.Config.t) =
    validate_h2_frame_size "h2_config.read_buffer_size"
      config.H2.Config.read_buffer_size;
    require_positive "h2_config.request_body_buffer_size"
      config.request_body_buffer_size;
    require_positive "h2_config.response_body_buffer_size"
      config.response_body_buffer_size;
    require_positive_int32 "h2_config.max_concurrent_streams"
      config.max_concurrent_streams;
    require_non_negative_int32 "h2_config.initial_window_size"
      config.initial_window_size

  let validate_h2_security_config
      (config : Eta_http.H2.Security.config) =
    require_positive "h2_security_config.max_settings_per_connection"
      config.max_settings_per_connection;
    require_positive "h2_security_config.max_goaway_per_connection"
      config.max_goaway_per_connection;
    require_positive "h2_security_config.max_rst_stream_per_connection"
      config.max_rst_stream_per_connection;
    require_positive "h2_security_config.max_ping_per_connection"
      config.max_ping_per_connection;
    require_positive "h2_security_config.max_empty_data_frames_per_connection"
      config.max_empty_data_frames_per_connection;
    require_positive "h2_security_config.max_window_update_per_connection"
      config.max_window_update_per_connection;
    require_positive "h2_security_config.max_hpack_block_bytes"
      config.max_hpack_block_bytes;
    require_positive "h2_security_config.max_continuation_accumulator_bytes"
      config.max_continuation_accumulator_bytes;
    require_positive "h2_security_config.max_response_headers_per_connection"
      config.max_response_headers_per_connection;
    require_positive "h2_security_config.max_header_name_bytes"
      config.max_header_name_bytes;
    require_positive "h2_security_config.max_header_value_bytes"
      config.max_header_value_bytes

  let validate t =
    require_positive "max_connections" t.max_connections;
    require_positive "backlog" t.backlog;
    require_positive "read_buffer_size" t.read_buffer_size;
    require_positive "command_queue_capacity" t.command_queue_capacity;
    require_positive_duration "tls_handshake_timeout"
      t.tls_handshake_timeout;
    Eta_http.Server.Config.validate t.server;
    validate_h2_config t.h2_config;
    Option.iter validate_h2_security_config t.h2_security_config
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
    listener_errors : int;
  }
end
