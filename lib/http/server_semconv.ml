(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Error = Server_error
module Request = Server_request
module Response = Server_response

let method_name method_ = Method.(method_ |> of_string |> to_string)

let protocol_version = function
  | Version.H1_0 -> "1.0"
  | H1_1 -> "1.1"
  | H2 -> "2"

let cons_opt key value attrs =
  match value with None -> attrs | Some value -> (key, value) :: attrs

let cons_int_opt key value attrs =
  match value with
  | None -> attrs
  | Some value -> (key, string_of_int value) :: attrs

let cons_bool key value attrs =
  (key, if value then "true" else "false") :: attrs

let request_attrs ?(emit_url_full = false) request =
  let query_attrs =
    match (request.Request.query, emit_url_full) with
    | None, _ -> []
    | Some query, true -> [ ("url.query", query) ]
    | Some _, false -> [ ("url.query.redacted", "<redacted>") ]
  in
  [
    ("http.request.method", method_name request.method_);
    ("url.scheme", request.scheme);
    ("url.path", request.path);
    ("network.protocol.name", "http");
    ("network.protocol.version", protocol_version request.version);
    ("eta_http.server.request_id", Lazy.force request.id);
    ("eta_http.server.connection_id", request.connection_id);
  ]
  @ query_attrs
  |> cons_opt "server.address" request.authority
  |> cons_opt "client.address" request.peer.address
  |> cons_int_opt "client.port" request.peer.port
  |> cons_int_opt "eta_http.server.stream_id" request.stream_id
  |> cons_bool "eta_http.server.tls" request.tls
  |> cons_opt "network.protocol.alpn" request.alpn_protocol

let response_attrs response =
  [ ("http.response.status_code", string_of_int (Response.status response)) ]

let error_attrs error =
  [
    ("error.type", Error.error_class error);
    ("eta_http.error.kind", Error.kind_name error.kind);
    ("eta_http.error.layer", Error.layer_to_string (Error.layer error));
  ]
