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
  module Response_write = Response_write
  module Write = Write
end

module H2 = struct
  module Admission = Eta_http_h2.Admission
  module Body = Eta_http_h2.Body
  module Connection = Eta_http_h2.Connection
  module Frame = Eta_http_h2.Frame
  module Hpack = Eta_http_h2.Hpack
  module Scheduler = Eta_http_h2.Scheduler
  module Security = Security
  module Settings = Eta_http_h2.Settings
  module Stream = Eta_http_h2.Stream
  module Stream_state = Eta_http_h2.Stream_state
  module Window = Eta_http_h2.Window

  module Headers = struct
    type t = (string * string) list

    let empty = []
    let to_list t = t
    let of_list t = t
    let of_rev_list t = List.rev t
    let get t name = List.assoc_opt name t
    let add t name value = (name, value) :: t
  end

  module Status = struct
    type t = int

    let of_code code = code
    let to_code status = status
  end

  module Method = struct
    type t = string

    let to_string t = t
    let of_string t = t
  end

  module Request = struct
    type t = {
      meth : string;
      scheme : string;
      authority : string option;
      path : string;
      headers : Headers.t;
    }

    let create ?(scheme = "http") ?(headers = Headers.empty) meth path =
      { meth; scheme; authority = None; path; headers }
  end

  module Response = struct
    type body = [ `Empty | `String of string | `Reader of Body.Reader.t ]

    type t = {
      status : Status.t;
      headers : Headers.t;
      body : body;
      trailers : Headers.t Lazy.t;
    }

    let create ?(headers = Headers.empty) ~status body =
      { status; headers; body; trailers = Lazy.from_val [] }
  end

  module Config = struct
    type t = {
      read_buffer_size : int;
      request_body_buffer_size : int;
      response_body_buffer_size : int;
      max_concurrent_streams : int;
      initial_window_size : int;
      max_header_list_size : int option;
      max_header_count : int;
    }

    let default =
      {
        read_buffer_size = 0x4000;
        request_body_buffer_size = 0x4000;
        response_body_buffer_size = 0x4000;
        max_concurrent_streams = 100;
        initial_window_size = 65535;
        max_header_list_size = None;
        max_header_count = Int.max_int;
      }

    let to_settings t =
      Settings.create ~max_frame_size:t.read_buffer_size
        ~max_concurrent_streams:t.max_concurrent_streams
        ~initial_window_size:t.initial_window_size
        ~max_header_list_size:t.max_header_list_size ()
  end

  module IOVec = struct
    type 'a t = 'a Eta_http_h2.Connection.iovec = {
      buffer : 'a;
      off : int;
      len : int;
    }

    let buffer t = t.buffer
    let off t = t.off
    let len t = t.len

    let lengthv iovecs =
      List.fold_left (fun acc t -> acc + t.len) 0 iovecs
  end

  module Error_code = Eta_http_h2.Error_code
end

module Ws = struct
  module Codec = Codec
end

module Hpack = Eta_http_h2.Hpack
