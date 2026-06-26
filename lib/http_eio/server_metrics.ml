(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Meter = Eta_http.Observability.Server.Meter
module Semconv = Eta_http.Observability.Server.Semconv

type t = {
  runtime : Eta_http.Server.Error.t Eta.Runtime.t;
  attrs : (string * string) list;
}

let cons_opt key value attrs =
  match value with None -> attrs | Some value -> (key, value) :: attrs

let cons_int_opt key value attrs =
  match value with
  | None -> attrs
  | Some value -> (key, string_of_int value) :: attrs

let bool value = if value then "true" else "false"

let transport_attrs (connection : Server_types.Connection_info.t) =
  [
    ( "eta_http.server.protocol",
      Eta_http.Server.Error.protocol_to_string connection.protocol );
    ("eta_http.server.tls", bool connection.tls);
  ]
  |> cons_opt "network.protocol.alpn" connection.alpn_protocol

let connection_attrs (connection : Server_types.Connection_info.t) =
  [
    ("eta_http.server.connection_id", connection.id);
    ("network.protocol.name", "http");
  ]
  @ transport_attrs connection
  |> cons_opt "client.address" connection.peer.address
  |> cons_int_opt "client.port" connection.peer.port

let connection ~runtime ~connection =
  { runtime; attrs = connection_attrs connection }

let request ~runtime ~connection ~emit_url_full request =
  {
    runtime;
    attrs =
      Semconv.request_attrs ~emit_url_full request
      @ transport_attrs connection;
  }

let run t operation =
  ignore (Eta.Runtime.run t.runtime operation : (unit, Eta_http.Server.Error.t) Eta.Exit.t)

let validate_non_negative name value =
  if value < 0 then
    invalid_arg ("Eta_http_eio.Server_metrics." ^ name ^ ": value must be >= 0")

let counter name t make value =
  validate_non_negative name value;
  if value > 0 then run t (make t.attrs value)

let active_connections t value =
  run t (Meter.active_connections ~attrs:t.attrs value)

let active_streams t value = run t (Meter.active_streams ~attrs:t.attrs value)

let requests_in_flight t value =
  run t (Meter.requests_in_flight ~attrs:t.attrs value)

let shutdown_active t value =
  run t (Meter.shutdown_active ~attrs:t.attrs value)

let requests_total t value =
  counter "requests_total" t
    (fun attrs value -> Meter.requests_total ~attrs value)
    value

let request_body_bytes t value =
  counter "request_body_bytes" t
    (fun attrs value -> Meter.request_body_bytes ~attrs value)
    value

let response_body_bytes t value =
  counter "response_body_bytes" t
    (fun attrs value -> Meter.response_body_bytes ~attrs value)
    value

let stream_resets t value =
  counter "stream_resets" t
    (fun attrs value -> Meter.stream_resets ~attrs value)
    value

let protocol_errors t value =
  counter "protocol_errors" t
    (fun attrs value -> Meter.protocol_errors ~attrs value)
    value

let request_started t = requests_in_flight t 1

let request_finished t =
  requests_total t 1;
  requests_in_flight t 0

let stream_started t = active_streams t 1
let stream_finished t = active_streams t 0
