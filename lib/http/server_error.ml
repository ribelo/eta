(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type protocol = H1 | H2 | H2c | Unknown

type layer =
  | Accept
  | Connection
  | Request_headers
  | Request_body
  | Handler
  | Response_headers
  | Response_body
  | Shutdown

type kind =
  | Bad_request of { message : string }
  | Header_invalid of { reason : string }
  | Request_body_too_large of { limit : int; length : int }
  | Request_timeout of { timeout_ms : int option }
  | Stream_admission_rejected of { limit : int }
  | Stream_reset of { code : string; message : string }
  | Connection_closed of { during : layer }
  | Protocol_error of { kind : string; message : string }
  | Handler_failed of { message : string }
  | Response_write_failed of { message : string }

type context = {
  method_ : string;
  target : string;
  protocol : protocol;
  stream_id : int option;
}

type t = {
  context : context;
  kind : kind;
}

let make ?(protocol = Unknown) ?stream_id ~method_ ~target kind =
  { context = { method_; target; protocol; stream_id }; kind }

let protocol_to_string = function
  | H1 -> "h1"
  | H2 -> "h2"
  | H2c -> "h2c"
  | Unknown -> "unknown"

let layer_to_string = function
  | Accept -> "accept"
  | Connection -> "connection"
  | Request_headers -> "request_headers"
  | Request_body -> "request_body"
  | Handler -> "handler"
  | Response_headers -> "response_headers"
  | Response_body -> "response_body"
  | Shutdown -> "shutdown"

let kind_name = function
  | Bad_request _ -> "Bad_request"
  | Header_invalid _ -> "Header_invalid"
  | Request_body_too_large _ -> "Request_body_too_large"
  | Request_timeout _ -> "Request_timeout"
  | Stream_admission_rejected _ -> "Stream_admission_rejected"
  | Stream_reset _ -> "Stream_reset"
  | Connection_closed _ -> "Connection_closed"
  | Protocol_error _ -> "Protocol_error"
  | Handler_failed _ -> "Handler_failed"
  | Response_write_failed _ -> "Response_write_failed"

let layer t =
  match t.kind with
  | Bad_request _ | Header_invalid _ | Stream_admission_rejected _ ->
      Request_headers
  | Request_body_too_large _ | Request_timeout _ -> Request_body
  | Stream_reset _ | Protocol_error _ -> Connection
  | Connection_closed { during } -> during
  | Handler_failed _ -> Handler
  | Response_write_failed _ -> Response_body

let error_class t =
  match t.kind with
  | Bad_request _ -> "bad_request"
  | Header_invalid _ -> "header_invalid"
  | Request_body_too_large _ -> "request_body_too_large"
  | Request_timeout _ -> "request_timeout"
  | Stream_admission_rejected _ -> "stream_admission_rejected"
  | Stream_reset _ -> "stream_reset"
  | Connection_closed _ -> "connection_closed"
  | Protocol_error _ -> "protocol_error"
  | Handler_failed _ -> "handler_failed"
  | Response_write_failed _ -> "response_write_failed"

let to_status t =
  match t.kind with
  | Bad_request _ | Header_invalid _ -> Some 400
  | Request_body_too_large _ -> Some 413
  | Request_timeout _ -> Some 408
  | Stream_admission_rejected _ -> Some 503
  | Handler_failed _ | Response_write_failed _ -> Some 500
  | Stream_reset _ | Connection_closed _ | Protocol_error _ -> None

let http_protocol = function
  | H1 -> Error.H1
  | H2 | H2c -> Error.H2
  | Unknown -> Error.Unknown

let to_http_layer = function
  | Accept | Connection -> Error.Tcp
  | Request_headers -> Error.Http_request
  | Request_body -> Error.Body_decode
  | Handler | Response_headers | Response_body -> Error.Http_response
  | Shutdown -> Error.Cancellation

let to_http_error t =
  let protocol = http_protocol t.context.protocol in
  let uri = t.context.target in
  let make kind = Error.make ~protocol ~method_:t.context.method_ ~uri kind in
  match t.kind with
  | Bad_request { message } ->
      make (Error.Connection_protocol_violation { kind = "bad_request"; message })
  | Header_invalid { reason } -> make (Error.Header_invalid { reason })
  | Request_body_too_large { limit; length } ->
      make (Error.Body_too_large { limit; length })
  | Request_timeout { timeout_ms } ->
      make (Error.Total_request_timeout { timeout_ms })
  | Stream_admission_rejected { limit } ->
      make (Error.Stream_admission_rejected { limit })
  | Stream_reset { code; message } ->
      make (Error.Connection_protocol_violation { kind = code; message })
  | Connection_closed { during } ->
      make (Error.Connection_closed { during = to_http_layer during })
  | Protocol_error { kind; message } ->
      make (Error.Connection_protocol_violation { kind; message })
  | Handler_failed { message } ->
      make (Error.Decode_error { codec = "eta-http-server-handler"; message })
  | Response_write_failed { message } ->
      make
        (Error.Connection_protocol_violation
           { kind = "response_write_failed"; message })

let pp fmt t =
  Format.fprintf fmt
    "eta-http-server error=%s method=%s target=%s protocol=%s layer=%s \
     error_class=%s"
    (kind_name t.kind) t.context.method_ (Redaction.uri t.context.target)
    (protocol_to_string t.context.protocol)
    (layer_to_string (layer t))
    (error_class t);
  (match t.context.stream_id with
  | None -> ()
  | Some stream_id -> Format.fprintf fmt " stream_id=%d" stream_id);
  match to_status t with
  | None -> ()
  | Some status -> Format.fprintf fmt " status=%d" status

let to_string t = Format.asprintf "%a" pp t
