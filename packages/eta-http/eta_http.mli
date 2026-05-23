(** Clean-room HTTP client for Eta.

    S1 foundations expose typed errors, request/response shapes, body streams,
    and the ADR 0002 TLS policy chokepoint. The h1 parser/writer, transport,
    pool integration, and live request path land later in S1. *)

module Core : sig
  module Header = Eta_http_core.Header
  module Method = Eta_http_core.Method
  module Span = Eta_http_core.Span
  module Status = Eta_http_core.Status
  module Url = Eta_http_core.Url
  module Version = Eta_http_core.Version
end
(** Core protocol values shared by HTTP/1.1 and HTTP/2. *)

module Body : sig
  module Chunked = Eta_http_body.Chunked
  module Source = Eta_http_body.Source
  module Stream = Eta_http_body.Stream
  module Transducer = Eta_http_body.Transducer
end
(** Request and response body surfaces. *)

module Client = Eta_http_client.Client
(** Top-level client API. *)

module Idempotency = Eta_http_client.Idempotency
(** HTTP method idempotency and request-body replayability classifier. *)

module Request = Eta_http_client.Request
(** Public request model. *)

module Response = Eta_http_client.Response
(** Public response model. *)

module Retry_policy = Eta_http_client.Retry
(** Retry policy and retry runner for eta-http requests. *)

module Error = Eta_http_error.Error
(** Typed eta-http error taxonomy. *)

module Error_projection = Eta_http_error.Projection
(** Structured error projections. *)

module Observability : sig
  module Meter = Eta_http_observability.Meter
  module Semconv = Eta_http_observability.Semconv
  module Tracer = Eta_http_observability.Tracer
end
(** OpenTelemetry semantic-convention helpers using Eta tracer/meter
    capabilities. *)

module Redaction = Eta_http_error.Redaction
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
  module Config = Eta_http_tls.Config
end
(** TLS policy chokepoint. *)

module Transport : sig
  module Alpn = Eta_http_transport.Alpn
  module Connect = Eta_http_transport.Connect
  module Dispatch = Eta_http_transport.Dispatch
end
(** DNS, TCP, TLS, ALPN, and protocol dispatch. *)

module H1 : sig
  module Client = Eta_http_h1.Client
  module Parse = Eta_http_h1.Parse
  module Write = Eta_http_h1.Write
end
(** HTTP/1.1 implementation modules. *)

module H2 : sig
  module Admission = Eta_http_h2.Admission
  module Frame = Eta_http_h2.Frame
  module Multiplexer = Eta_http_h2.Multiplexer
  module Security = Eta_http_h2.Security
  module Stream_state = Eta_http_h2.Stream_state
  module Writer = Eta_http_h2.Writer
end
(** HTTP/2 implementation modules. *)
