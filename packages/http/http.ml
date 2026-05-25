(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Public entry point for eta-http. *)

module Core = struct
  module Header = Http_core.Header
  module Method = Http_core.Method
  module Span = Http_core.Span
  module Status = Http_core.Status
  module Url = Http_core.Url
  module Version = Http_core.Version
end

module Body = struct
  module Chunked = Http_body.Chunked
  module Source = Http_body.Source
  module Stream = Http_body.Stream
  module Transducer = Http_body.Transducer
end

module Client = Http_client.Client
module Idempotency = Http_client.Idempotency
module Request = Http_client.Request
module Response = Http_client.Response
module Retry_policy = Http_client.Retry
module Error = Http_error.Error
module Error_projection = Http_error.Projection
module Observability = struct
  module Meter = Http_observability.Meter
  module Semconv = Http_observability.Semconv
  module Tracer = Http_observability.Tracer
end
module Redaction = Http_error.Redaction

let request = Client.request
let request_with_retry = Client.request_with_retry

module Tls = struct
  module Config = Http_tls.Config
  module Eio = Http_tls.Eio
end

module Transport = struct
  module Alpn = Http_transport.Alpn
  module Connect = Http_transport.Connect
  module Dispatch = Http_transport.Dispatch
end

module H1 = struct
  module Client = Http_h1.Client
  module Parse = Http_h1.Parse
  module Write = Http_h1.Write
end

module H2 = struct
  module Admission = Http_h2.Admission
  module Connection = Http_h2.Connection
  module Frame = Http_h2.Frame
  module Multiplexer = Http_h2.Multiplexer
  module Security = Http_h2.Security
  module Stream_state = Http_h2.Stream_state
  module Writer = Http_h2.Writer
end
