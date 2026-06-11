(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

let record_metric ?(attrs = []) ~name ~description ~unit_ ~kind value =
  Eta.Effect.metric_update ~name ~description ~unit_ ~attrs ~kind
    (Eta.Capabilities.Int value)

let gauge ?attrs ~name ~description ~unit_ value =
  record_metric ?attrs ~name ~description ~unit_ ~kind:Eta.Capabilities.Gauge
    value

let counter ?attrs ~name ~description ~unit_ value =
  record_metric ?attrs ~name ~description ~unit_
    ~kind:Eta.Capabilities.Counter_monotonic value

let active_connections ?attrs value =
  gauge ?attrs ~name:"eta_http.server.connections.active"
    ~description:"Active eta-http server connections" ~unit_:"{connection}" value

let active_streams ?attrs value =
  gauge ?attrs ~name:"eta_http.server.streams.active"
    ~description:"Active eta-http server streams" ~unit_:"{stream}" value

let requests_total ?attrs value =
  counter ?attrs ~name:"eta_http.server.requests.total"
    ~description:"Total eta-http server requests" ~unit_:"{request}" value

let requests_in_flight ?attrs value =
  gauge ?attrs ~name:"eta_http.server.requests.in_flight"
    ~description:"In-flight eta-http server requests" ~unit_:"{request}" value

let request_body_bytes ?attrs value =
  counter ?attrs ~name:"eta_http.server.request.body.bytes"
    ~description:"Eta-http server request body bytes" ~unit_:"By" value

let response_body_bytes ?attrs value =
  counter ?attrs ~name:"eta_http.server.response.body.bytes"
    ~description:"Eta-http server response body bytes" ~unit_:"By" value

let stream_resets ?attrs value =
  counter ?attrs ~name:"eta_http.server.stream.resets"
    ~description:"Eta-http server stream resets" ~unit_:"{reset}" value

let protocol_errors ?attrs value =
  counter ?attrs ~name:"eta_http.server.protocol.errors"
    ~description:"Eta-http server protocol errors" ~unit_:"{error}" value

let shutdown_active ?attrs value =
  gauge ?attrs ~name:"eta_http.server.shutdown.active"
    ~description:"Active eta-http server shutdown" ~unit_:"{shutdown}" value
