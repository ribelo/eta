(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type shutdown =
  | Graceful of Eta.Duration.t
  | Immediate

type domain_policy =
  | Single_domain
  | Recommended
  | Additional of int

type time = {
  now_ms : unit -> int64;
  sleep : Eta.Duration.t -> unit;
  with_timeout : 'a. Eta.Duration.t -> (unit -> 'a) -> 'a;
}

let live_time clock =
  let now_ms () = Int64.of_float (Eio.Time.now clock *. 1000.) in
  {
    now_ms;
    sleep =
      (fun duration ->
        Eio.Time.sleep clock (Eta.Duration.to_seconds_float duration));
    with_timeout =
      (fun duration f ->
        Eio.Time.with_timeout_exn clock
          (Eta.Duration.to_seconds_float duration)
          f);
  }

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
    h2_config : Eta_http.H2.Config.t;
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
      h2_config = { Eta_http.H2.Config.default with max_concurrent_streams = 128 };
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

  let require_non_negative name value =
    if value < 0 then invalid_arg (field name ^ " must be >= 0")

  let require_non_negative_int32 name value =
    if Int32.compare value 0l < 0 then
      invalid_arg (field name ^ " must be >= 0")

  let max_h2_concurrent_streams = 4096

  let validate_h2_max_concurrent_streams name value =
    require_positive name value;
    if value > max_h2_concurrent_streams then
      invalid_arg
        (field name ^ " must be <= "
        ^ string_of_int max_h2_concurrent_streams)

  let validate_h2_frame_size name value =
    if value < 0x4000 || value > 0xffffff then
      invalid_arg (field name ^ " must be between 16384 and 16777215")

  let validate_h2_config (config : Eta_http.H2.Config.t) =
    validate_h2_frame_size "h2_config.read_buffer_size"
      config.Eta_http.H2.Config.read_buffer_size;
    require_positive "h2_config.request_body_buffer_size"
      config.request_body_buffer_size;
    require_positive "h2_config.response_body_buffer_size"
      config.response_body_buffer_size;
    validate_h2_max_concurrent_streams "h2_config.max_concurrent_streams"
      config.max_concurrent_streams;
    require_non_negative "h2_config.initial_window_size"
      config.initial_window_size;
    Option.iter
      (require_positive "h2_config.max_header_list_size")
      config.max_header_list_size;
    require_positive "h2_config.max_header_count" config.max_header_count

  let validate_h2_security_config
      (config : Eta_http.H2.Security.config) =
    let require_rate_limit name (limit : Eta_http.H2.Security.rate_limit) =
      require_positive (name ^ ".burst") limit.burst;
      require_positive (name ^ ".window_ms") limit.window_ms;
      Option.iter
        (require_positive (name ^ ".max_per_connection"))
        limit.max_per_connection
    in
    require_rate_limit "h2_security_config.settings_rate"
      config.settings_rate;
    require_positive "h2_security_config.max_goaway_per_connection"
      config.max_goaway_per_connection;
    require_rate_limit "h2_security_config.rst_stream_rate"
      config.rst_stream_rate;
    require_rate_limit "h2_security_config.ping_rate" config.ping_rate;
    require_rate_limit "h2_security_config.empty_data_rate"
      config.empty_data_rate;
    require_rate_limit "h2_security_config.window_update_rate"
      config.window_update_rate;
    require_positive "h2_security_config.max_hpack_block_bytes"
      config.max_hpack_block_bytes;
    require_positive "h2_security_config.max_continuation_accumulator_bytes"
      config.max_continuation_accumulator_bytes;
    require_positive "h2_security_config.max_response_headers_per_stream"
      config.max_response_headers_per_stream;
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
