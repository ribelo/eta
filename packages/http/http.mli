(** Clean-room HTTP client for Eta.

    S1 foundations expose typed errors, request/response shapes, body streams,
    and the ADR 0002 TLS policy chokepoint. The h1 parser/writer, transport,
    pool integration, and live request path land later in S1. *)

module Core : sig
  module Header = Http_core.Header
  module Method = Http_core.Method
  module Span = Http_core.Span
  module Status = Http_core.Status
  module Url = Http_core.Url
  module Version = Http_core.Version
end
(** Core protocol values shared by HTTP/1.1 and HTTP/2. *)

module Body : sig
  module Chunked = Http_body.Chunked
  module Source = Http_body.Source
  module Stream = Http_body.Stream
  module Transducer = Http_body.Transducer
end
(** Request and response body surfaces. *)

module Client = Http_client.Client
(** Top-level client API. *)

module Idempotency = Http_client.Idempotency
(** HTTP method idempotency and request-body replayability classifier. *)

module Request = Http_client.Request
(** Public request model. *)

module Response = Http_client.Response
(** Public response model. *)

module Retry_policy = Http_client.Retry
(** Retry policy and retry runner for eta-http requests. *)

module Error = Http_error.Error
(** Typed eta-http error taxonomy. *)

module Error_projection = Http_error.Projection
(** Structured error projections. *)

module Observability : sig
  module Meter = Http_observability.Meter
  module Semconv = Http_observability.Semconv
  module Tracer = Http_observability.Tracer
end
(** OpenTelemetry semantic-convention helpers using Eta tracer/meter
    capabilities. *)

module Redaction = Http_error.Redaction
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
  module Config = Http_tls.Config
  module Eio = Http_tls.Eio
end
(** TLS policy chokepoint. *)

module Transport : sig
  module Alpn = Http_transport.Alpn
  module Connect = Http_transport.Connect
  module Dispatch = Http_transport.Dispatch
end
(** DNS, TCP, TLS, ALPN, and protocol dispatch. *)

module H1 : sig
  module Client = Http_h1.Client
  module Parse = Http_h1.Parse
  module Write = Http_h1.Write
end
(** HTTP/1.1 implementation modules. *)

module H2 : sig
  module Admission = Http_h2.Admission
  module Connection = Http_h2.Connection
  module Frame = Http_h2.Frame
  module Multiplexer = Http_h2.Multiplexer
  module Security = Http_h2.Security
  module Stream_state = Http_h2.Stream_state
  module Writer = Http_h2.Writer
end
(** HTTP/2 implementation modules. *)

module Ws : sig
  module Client = Http_ws.Client
  module Codec = Http_ws.Codec
end
(** WebSocket upgrade client and RFC 6455 codec. *)
