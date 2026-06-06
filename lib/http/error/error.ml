(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type protocol = H1 | H2 | Unknown

type layer =
  | Tcp
  | Tls
  | Alpn
  | Pool
  | Http_request
  | Http_response
  | Body_decode
  | Cancellation

type retryability =
  | Retryable
  | Retryable_if_body_replayable
  | Not_retryable

type tls_stage = Tls_handshake | Alpn_negotiation

type certificate_reason =
  | Expired
  | Name_mismatch
  | Untrusted_chain
  | Revoked
  | Certificate_policy_error of string

type kind =
  | Dns_error of { host : string; message : string }
  | Connect_error of { message : string }
  | Connect_timeout of { timeout_ms : int option }
  | Tls_handshake_error of { stage : tls_stage; message : string }
  | Tls_certificate_error of { reason : certificate_reason; message : string }
  | Connection_closed of { during : layer }
  | Pool_shutdown
  | Pool_acquire_timeout of { timeout_ms : int option }
  | Response_header_timeout of { timeout_ms : int option }
  | Response_body_idle_timeout of { timeout_ms : int option }
  | Total_request_timeout of { timeout_ms : int option }
  | HTTP_status of { status : int; headers : (string * string) list }
  | Decode_error of { codec : string; message : string }
  | Body_too_large of { limit : int; length : int }
  | Connection_protocol_violation of { kind : string; message : string }
  | Hpack_decode_overflow of { decoded_bytes : int; limit_bytes : int }
  | Continuation_flood of {
      accumulated_bytes : int;
      limit_bytes : int;
      frames : int;
    }
  | Stream_admission_rejected of { limit : int }
  | Rst_rate_exceeded of { observed_per_second : int; limit_per_second : int }
  | Ping_rate_exceeded of { observed_rate_hz : int; limit_hz : int }
  | Settings_churn_rate_exceeded of {
      observed_rate_hz : int;
      limit_hz : int;
    }
  | Response_header_change_rate_exceeded of {
      observed_rate_hz : int;
      limit_hz : int;
    }
  | Header_invalid of { reason : string }

type context = {
  method_ : string;
  uri : string;
  protocol : protocol;
}

type t = {
  context : context;
  kind : kind;
}

let make ?(protocol = Unknown) ~method_ ~uri kind =
  { context = { method_; uri; protocol }; kind }

let protocol_to_string = function
  | H1 -> "h1"
  | H2 -> "h2"
  | Unknown -> "unknown"

let layer_to_string = function
  | Tcp -> "tcp"
  | Tls -> "tls"
  | Alpn -> "alpn"
  | Pool -> "pool"
  | Http_request -> "http_request"
  | Http_response -> "http_response"
  | Body_decode -> "body_decode"
  | Cancellation -> "cancellation"

let retryability_to_string = function
  | Retryable -> "retryable"
  | Retryable_if_body_replayable -> "retryable_if_body_replayable"
  | Not_retryable -> "not_retryable"

let kind_name = function
  | Dns_error _ -> "Dns_error"
  | Connect_error _ -> "Connect_error"
  | Connect_timeout _ -> "Connect_timeout"
  | Tls_handshake_error _ -> "Tls_handshake_error"
  | Tls_certificate_error _ -> "Tls_certificate_error"
  | Connection_closed _ -> "Connection_closed"
  | Pool_shutdown -> "Pool_shutdown"
  | Pool_acquire_timeout _ -> "Pool_acquire_timeout"
  | Response_header_timeout _ -> "Response_header_timeout"
  | Response_body_idle_timeout _ -> "Response_body_idle_timeout"
  | Total_request_timeout _ -> "Total_request_timeout"
  | HTTP_status _ -> "HTTP_status"
  | Decode_error _ -> "Decode_error"
  | Body_too_large _ -> "Body_too_large"
  | Connection_protocol_violation _ -> "Connection_protocol_violation"
  | Hpack_decode_overflow _ -> "Hpack_decode_overflow"
  | Continuation_flood _ -> "Continuation_flood"
  | Stream_admission_rejected _ -> "Stream_admission_rejected"
  | Rst_rate_exceeded _ -> "Rst_rate_exceeded"
  | Ping_rate_exceeded _ -> "Ping_rate_exceeded"
  | Settings_churn_rate_exceeded _ -> "Settings_churn_rate_exceeded"
  | Response_header_change_rate_exceeded _ ->
      "Response_header_change_rate_exceeded"
  | Header_invalid _ -> "Header_invalid"

let layer t =
  match t.kind with
  | Dns_error _ | Connect_error _ | Connect_timeout _ -> Tcp
  | Tls_handshake_error { stage = Tls_handshake; _ } -> Tls
  | Tls_handshake_error { stage = Alpn_negotiation; _ } -> Alpn
  | Tls_certificate_error _ -> Tls
  | Connection_closed { during } -> during
  | Pool_shutdown | Pool_acquire_timeout _ -> Pool
  | Response_header_timeout _ | Total_request_timeout _ -> Http_request
  | Response_body_idle_timeout _ | HTTP_status _ -> Http_response
  | Decode_error _ | Body_too_large _ -> Body_decode
  | Connection_protocol_violation _ | Hpack_decode_overflow _
  | Continuation_flood _ | Stream_admission_rejected _ | Rst_rate_exceeded _
  | Ping_rate_exceeded _ | Settings_churn_rate_exceeded _
  | Response_header_change_rate_exceeded _ | Header_invalid _ ->
      Http_response

let retryability t =
  match t.kind with
  | Tls_certificate_error _ -> Not_retryable
  | Tls_handshake_error { stage = Alpn_negotiation; _ } -> Not_retryable
  | Decode_error _ -> Retryable_if_body_replayable
  | Body_too_large _ -> Not_retryable
  | HTTP_status { status; _ } when status = 408 || status = 429 ->
      Retryable_if_body_replayable
  | HTTP_status { status; _ } when status >= 500 && status <= 599 ->
      Retryable_if_body_replayable
  | HTTP_status _ -> Not_retryable
  | Connection_protocol_violation _ | Hpack_decode_overflow _
  | Continuation_flood _ | Stream_admission_rejected _ | Rst_rate_exceeded _
  | Ping_rate_exceeded _ | Settings_churn_rate_exceeded _
  | Response_header_change_rate_exceeded _ | Header_invalid _ ->
      Not_retryable
  | Pool_shutdown -> Not_retryable
  | Dns_error _ | Connect_error _ | Connect_timeout _ | Pool_acquire_timeout _
  | Response_header_timeout _ | Response_body_idle_timeout _
  | Total_request_timeout _ | Connection_closed _ | Tls_handshake_error _ ->
      Retryable_if_body_replayable

let status t = match t.kind with HTTP_status { status; _ } -> Some status | _ -> None

let status_class t =
  match status t with
  | None -> None
  | Some status when status >= 100 && status <= 599 ->
      Some (string_of_int (status / 100) ^ "xx")
  | Some _ -> Some "invalid"

let error_class t =
  match t.kind with
  | Dns_error _ -> "dns_error"
  | Connect_error _ -> "connect_error"
  | Connect_timeout _ -> "connect_timeout"
  | Tls_handshake_error { stage = Tls_handshake; _ } -> "tls_handshake_error"
  | Tls_handshake_error { stage = Alpn_negotiation; _ } ->
      "alpn_negotiation_error"
  | Tls_certificate_error _ -> "tls_certificate_error"
  | Connection_closed _ -> "connection_closed"
  | Pool_shutdown -> "pool_shutdown"
  | Pool_acquire_timeout _ -> "pool_acquire_timeout"
  | Response_header_timeout _ -> "response_header_timeout"
  | Response_body_idle_timeout _ -> "response_body_idle_timeout"
  | Total_request_timeout _ -> "total_request_timeout"
  | HTTP_status _ -> (
      match status_class t with
      | Some class_ -> "http_status_" ^ class_
      | None -> "http_status")
  | Decode_error _ -> "decode_error"
  | Body_too_large _ -> "body_too_large"
  | Connection_protocol_violation _ -> "connection_protocol_violation"
  | Hpack_decode_overflow _ -> "hpack_decode_overflow"
  | Continuation_flood _ -> "continuation_flood"
  | Stream_admission_rejected _ -> "stream_admission_rejected"
  | Rst_rate_exceeded _ -> "rst_rate_exceeded"
  | Ping_rate_exceeded _ -> "ping_rate_exceeded"
  | Settings_churn_rate_exceeded _ -> "settings_churn_rate_exceeded"
  | Response_header_change_rate_exceeded _ ->
      "response_header_change_rate_exceeded"
  | Header_invalid _ -> "header_invalid"

let headers t =
  match t.kind with HTTP_status { headers; _ } -> headers | _ -> []

let pp fmt t =
  Format.fprintf fmt
    "eta-http error=%s method=%s uri=%s protocol=%s layer=%s retryability=%s \
     error_class=%s"
    (kind_name t.kind) t.context.method_ (Redaction.uri t.context.uri)
    (protocol_to_string t.context.protocol)
    (layer_to_string (layer t))
    (retryability_to_string (retryability t))
    (error_class t);
  (match status t with
  | None -> ()
  | Some status ->
      Format.fprintf fmt " status=%d status_class=%s" status
        (Option.value ~default:"none" (status_class t)));
  (match headers t with
  | [] -> ()
  | headers ->
      let pp_header fmt (name, value) =
        let value = if Redaction.is_sensitive name then "<redacted>" else value in
        Format.fprintf fmt "%s=%s" name value
      in
      Format.fprintf fmt " headers=[%a]"
        (Format.pp_print_list ~pp_sep:(fun fmt () -> Format.fprintf fmt "; ")
           pp_header)
        headers);
  Format.fprintf fmt " body=<omitted>"

let to_string t = Format.asprintf "%a" pp t
