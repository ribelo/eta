(** Backend-neutral HTTP surface for Eta.

    This package owns the shared request/response model, typed errors, body
    streams, retry policy handling, trace-context propagation, TLS policy data,
    and pure protocol helpers. Runtime transports live in adapter packages such
    as [eta_http_eio]. *)

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

module Server = Server
(** Backend-neutral server API. *)

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

  module Server : sig
    module Meter = Server_meter
    module Semconv = Server_semconv
    module Tracer = Server_tracer
  end
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
  module OpenSSL = Openssl
end
(** TLS policy and low-level protocol helpers. *)

module Transport : sig
  module Alpn = Alpn
  module Dispatch = Dispatch
end
(** Backend-neutral ALPN and protocol dispatch helpers. *)

module H1 : sig
  module Parse = Parse
  module Write = Write
end
(** HTTP/1.1 parser and serializer modules. *)

module H2 : sig
  module Admission = Admission
  module Frame = Frame
  module Informational_filter = Informational_filter
  module Security = Security
  module Stream_state = Stream_state
end
(** HTTP/2 protocol helpers that do not own sockets or scheduler state. *)

module Ws : sig
  module Codec = Codec
end
(** RFC 6455 codec. *)
