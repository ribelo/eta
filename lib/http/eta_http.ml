(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(** Public entry point for eta-http. *)

module Core = struct
  module Header = Header
  module Method = Method
  module Span = Span
  module Status = Status
  module Url = Url
  module Version = Version
end

module Body = struct
  module Chunked = Chunked
  module Source = Source
  module Stream = Stream
  module Transducer = Transducer
end

module Client = Client
module Server = Server
module Idempotency = Idempotency
module Request = Request
module Response = Response
module Trace_context = Trace_context
module Retry_policy = Retry
module Error = Error
module Error_projection = Projection
module Observability = struct
  module Meter = Meter
  module Semconv = Semconv
  module Tracer = Tracer

  module Server = struct
    module Meter = Server_meter
    module Semconv = Server_semconv
    module Tracer = Server_tracer
  end
end
module Redaction = Redaction

let request = Client.request
let request_with_retry = Client.request_with_retry

module Tls = struct
  module Config = Config
  module OpenSSL = Openssl
end

module Transport = struct
  module Alpn = Alpn
  module Dispatch = Dispatch
end

module H1 = struct
  module Request_body = Request_body
  module Parse = Parse
  module Request_parse = Request_parse
  module Write = Write
end

module H2 = struct
  module Admission = Admission
  module Frame = Frame
  module Informational_filter = Informational_filter
  module Security = Security
  module Stream_state = Stream_state
end

module Ws = struct
  module Codec = Codec
end
