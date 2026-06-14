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
  module Request_body = Request_body
  module Parse = Parse
  module Request_parse = Request_parse
  module Response_write = Response_write
  module Write = Write
end
(** HTTP/1.1 parser and serializer modules. *)

module H2 : sig
  module Admission = Eta_http_h2.Admission
  module Body = Eta_http_h2.Body
  module Config : sig
    type t = {
      read_buffer_size : int;
      request_body_buffer_size : int;
      response_body_buffer_size : int;
      max_concurrent_streams : int;
      initial_window_size : int;
      max_header_list_size : int option;
      max_header_count : int;
    }

    val default : t
    val to_settings : t -> Eta_http_h2.Settings.t
  end

  module Connection = Eta_http_h2.Connection
  module Error_code = Eta_http_h2.Error_code
  module Frame = Eta_http_h2.Frame
  module Hpack = Eta_http_h2.Hpack

  module Headers : sig
    type t = (string * string) list

    val empty : t
    val to_list : t -> (string * string) list
    val of_list : (string * string) list -> t
    val of_rev_list : (string * string) list -> t
    val get : t -> string -> string option
    val add : t -> string -> string -> t
  end

  module IOVec : sig
    type 'a t = 'a Eta_http_h2.Connection.iovec = {
      buffer : 'a;
      off : int;
      len : int;
    }

    val buffer : 'a t -> 'a
    val off : 'a t -> int
    val len : 'a t -> int
    val lengthv : 'a t list -> int
  end

  module Method : sig
    type t = string

    val to_string : t -> string
    val of_string : string -> t
  end

  module Request : sig
    type t = {
      meth : string;
      scheme : string;
      authority : string option;
      path : string;
      headers : Headers.t;
    }

    val create : ?scheme:string -> ?headers:Headers.t -> string -> string -> t
  end

  module Response : sig
    type body = [ `Empty | `String of string | `Reader of Body.Reader.t ]

    type t = {
      status : int;
      headers : Headers.t;
      body : body;
      trailers : Headers.t Lazy.t;
    }

    val create : ?headers:Headers.t -> status:int -> body -> t
  end

  module Security = Security
  module Settings = Eta_http_h2.Settings
  module Status : sig
    type t = int

    val of_code : int -> t
    val to_code : t -> int
  end

  module Stream = Eta_http_h2.Stream
  module Stream_state = Eta_http_h2.Stream_state
  module Window = Eta_http_h2.Window
end
(** HTTP/2 protocol helpers that do not own sockets or scheduler state. *)

module Ws : sig
  module Codec = Codec
end
(** RFC 6455 codec. *)

module Hpack = Eta_http_h2.Hpack
(** HPACK codec used by the in-house HTTP/2 implementation. *)
