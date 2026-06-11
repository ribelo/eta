(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

let add_non_negative current amount =
  if amount < 0 then
    invalid_arg "Eta_http_eio.Server_stats: counter increment must be >= 0";
  current + amount

module Listener = struct
  type snapshot = {
    active_connections : int;
    opened_connections : int;
    closed_connections : int;
    tls_handshakes : int;
    tls_handshake_failures : int;
    alpn_h1 : int;
    alpn_h2 : int;
    alpn_rejected : int;
  }

  type t = {
    mutable opened_connections : int;
    mutable closed_connections : int;
    mutable tls_handshakes : int;
    mutable tls_handshake_failures : int;
    mutable alpn_h1 : int;
    mutable alpn_h2 : int;
    mutable alpn_rejected : int;
  }

  let create () =
    {
      opened_connections = 0;
      closed_connections = 0;
      tls_handshakes = 0;
      tls_handshake_failures = 0;
      alpn_h1 = 0;
      alpn_h2 = 0;
      alpn_rejected = 0;
    }

  let opened_connection t =
    t.opened_connections <- t.opened_connections + 1

  let closed_connection t =
    t.closed_connections <- t.closed_connections + 1

  let tls_handshake t = t.tls_handshakes <- t.tls_handshakes + 1

  let tls_handshake_failure t =
    t.tls_handshake_failures <- t.tls_handshake_failures + 1

  let alpn_h1 t = t.alpn_h1 <- t.alpn_h1 + 1
  let alpn_h2 t = t.alpn_h2 <- t.alpn_h2 + 1
  let alpn_rejected t = t.alpn_rejected <- t.alpn_rejected + 1

  let snapshot t ~active_connections : snapshot =
    {
      active_connections;
      opened_connections = t.opened_connections;
      closed_connections = t.closed_connections;
      tls_handshakes = t.tls_handshakes;
      tls_handshake_failures = t.tls_handshake_failures;
      alpn_h1 = t.alpn_h1;
      alpn_h2 = t.alpn_h2;
      alpn_rejected = t.alpn_rejected;
    }
end

module H1 = struct
  type snapshot = {
    active_requests : int;
    completed_requests : int;
    request_bytes : int;
    response_bytes : int;
    protocol_errors : int;
  }

  type t = {
    mutable active_requests : int;
    mutable completed_requests : int;
    mutable request_bytes : int;
    mutable response_bytes : int;
    mutable protocol_errors : int;
  }

  let create () =
    {
      active_requests = 0;
      completed_requests = 0;
      request_bytes = 0;
      response_bytes = 0;
      protocol_errors = 0;
    }

  let request_started t = t.active_requests <- t.active_requests + 1

  let request_completed t =
    if t.active_requests > 0 then t.active_requests <- t.active_requests - 1;
    t.completed_requests <- t.completed_requests + 1

  let add_request_bytes t amount =
    t.request_bytes <- add_non_negative t.request_bytes amount

  let add_response_bytes t amount =
    t.response_bytes <- add_non_negative t.response_bytes amount

  let protocol_error t = t.protocol_errors <- t.protocol_errors + 1

  let snapshot t : snapshot =
    {
      active_requests = t.active_requests;
      completed_requests = t.completed_requests;
      request_bytes = t.request_bytes;
      response_bytes = t.response_bytes;
      protocol_errors = t.protocol_errors;
    }
end

module H2 = struct
  type snapshot = {
    active_streams : int;
    opened_streams : int;
    completed_streams : int;
    reset_streams : int;
    request_bytes : int;
    response_bytes : int;
    protocol_errors : int;
  }

  type t = {
    mutable opened_streams : int;
    mutable completed_streams : int;
    mutable reset_streams : int;
    mutable request_bytes : int;
    mutable response_bytes : int;
    mutable protocol_errors : int;
  }

  let create () =
    {
      opened_streams = 0;
      completed_streams = 0;
      reset_streams = 0;
      request_bytes = 0;
      response_bytes = 0;
      protocol_errors = 0;
    }

  let stream_opened t = t.opened_streams <- t.opened_streams + 1
  let stream_completed t = t.completed_streams <- t.completed_streams + 1
  let stream_reset t = t.reset_streams <- t.reset_streams + 1

  let add_reset_streams t amount =
    t.reset_streams <- add_non_negative t.reset_streams amount

  let add_request_bytes t amount =
    t.request_bytes <- add_non_negative t.request_bytes amount

  let add_response_bytes t amount =
    t.response_bytes <- add_non_negative t.response_bytes amount

  let protocol_error t = t.protocol_errors <- t.protocol_errors + 1

  let snapshot t ~active_streams : snapshot =
    {
      active_streams;
      opened_streams = t.opened_streams;
      completed_streams = t.completed_streams;
      reset_streams = t.reset_streams;
      request_bytes = t.request_bytes;
      response_bytes = t.response_bytes;
      protocol_errors = t.protocol_errors;
    }
end
