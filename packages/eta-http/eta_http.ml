(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Public entry point for eta-http. *)

module Core = struct
  module Header = Eta_http_core.Header
  module Method = Eta_http_core.Method
  module Span = Eta_http_core.Span
  module Status = Eta_http_core.Status
  module Url = Eta_http_core.Url
  module Version = Eta_http_core.Version
end

module Body = struct
  module Chunked = Eta_http_body.Chunked
  module Source = Eta_http_body.Source
  module Stream = Eta_http_body.Stream
  module Transducer = Eta_http_body.Transducer
end

module Client = Eta_http_client.Client
module Idempotency = Eta_http_client.Idempotency
module Request = Eta_http_client.Request
module Response = Eta_http_client.Response
module Retry_policy = Eta_http_client.Retry
module Error = Eta_http_error.Error
module Error_projection = Eta_http_error.Projection
module Observability = struct
  module Meter = Eta_http_observability.Meter
  module Semconv = Eta_http_observability.Semconv
  module Tracer = Eta_http_observability.Tracer
end
module Redaction = Eta_http_error.Redaction

let request = Client.request
let request_with_retry = Client.request_with_retry

module Tls = struct
  module Config = Eta_http_tls.Config
end

module Transport = struct
  module Alpn = Eta_http_transport.Alpn
  module Connect = Eta_http_transport.Connect
  module Dispatch = Eta_http_transport.Dispatch
end

module H1 = struct
  module Client = Eta_http_h1.Client
  module Parse = Eta_http_h1.Parse
  module Write = Eta_http_h1.Write
end

module H2 = struct
  module Admission = Eta_http_h2.Admission
  module Connection = Eta_http_h2.Connection
  module Frame = Eta_http_h2.Frame
  module Multiplexer = Eta_http_h2.Multiplexer
  module Security = Eta_http_h2.Security
  module Stream_state = Eta_http_h2.Stream_state
  module Writer = Eta_http_h2.Writer
end
