(** Clean-room HTTP client for Eta.

    The public surface exposes typed errors, request/response models, body
    streams, retry policy handling, trace-context propagation, TLS policy,
    transport dispatch, HTTP/1.1 and HTTP/2 implementation modules, and a
    WebSocket upgrade client. *)

module Core : sig
  module Header = Header
  module Method = Method
  module Span = Span
  module Status = Status
  module Url = Url
  module Version = Version
end
(** Core protocol values shared by HTTP/1.1 and HTTP/2. *)

module Body : sig
  module Chunked = Chunked
  module Source = Source
  module Stream = Stream
  module Transducer = Transducer
end
(** Request and response body surfaces. *)

module Client = Client
(** Top-level client API. *)

module Idempotency = Idempotency
(** HTTP method idempotency and request-body replayability classifier. *)

module Request = Request
(** Public request model. *)

module Response = Response
(** Public response model. *)

module Trace_context = Trace_context
(** W3C trace-context helpers for eta-http request values. *)

module Retry_policy = Retry
(** Retry policy and retry runner for eta-http requests. *)

module Error = Error
(** Typed eta-http error taxonomy. *)

module Error_projection = Projection
(** Structured error projections. *)

module Observability : sig
  module Meter = Meter
  module Semconv = Semconv
  module Tracer = Tracer
end
(** OpenTelemetry semantic-convention helpers using Eta tracer/meter
    capabilities. *)

module Redaction = Redaction
(** Diagnostic redaction helpers. *)

val request :
  Client.t -> Request.t -> (Response.t, Error.t) Eta.Effect.t
(** Submit a request through the supplied client. *)

val request_with_retry :
  ?policy:Retry_policy.t ->
  Client.t ->
  Request.t ->
  (Response.t, Error.t) Eta.Effect.t
(** Submit a request through the supplied client with retry policy handling. *)

module Tls : sig
  module Config = Config
  module Eio = Tls_eio
end
(** TLS policy chokepoint. *)

module Transport : sig
  module Alpn = Alpn
  module Connect = Connect
  module Dispatch = Dispatch
end
(** DNS, TCP, TLS, ALPN, and protocol dispatch. *)

module H1 : sig
  module Client = H1_client
  module Parse = Parse
  module Write = Write
end
(** HTTP/1.1 implementation modules. *)

module H2 : sig
  module Admission = Admission
  module Connection = Connection
  module Frame = Frame
  module Informational_filter = Informational_filter
  module Multiplexer = Multiplexer
  module Security = Security
  module Stream_state = Stream_state
  module Writer = Writer
end
(** HTTP/2 implementation modules. *)

module Ws : sig
  module Client = Ws_client
  module Codec = Codec
end
(** WebSocket upgrade client and RFC 6455 codec. *)
