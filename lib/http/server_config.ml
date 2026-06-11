(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type unread_body_policy =
  | Reset
  | Drain_up_to of int

type limits = {
  max_request_line_bytes : int;
  max_request_header_bytes : int;
  max_request_headers : int;
  max_request_body_bytes : int option;
  max_response_header_bytes : int;
  max_response_headers : int;
  max_trailer_bytes : int;
  max_trailers : int;
}

type timeouts = {
  request_header_timeout : Eta.Duration.t option;
  request_body_timeout : Eta.Duration.t option;
  response_write_timeout : Eta.Duration.t option;
  response_body_timeout : Eta.Duration.t option;
  idle_timeout : Eta.Duration.t option;
  handler_timeout : Eta.Duration.t option;
}

type t = {
  limits : limits;
  timeouts : timeouts;
  unread_body_policy : unread_body_policy;
  enable_otel : bool;
  emit_url_full : bool;
}

let default_limits =
  {
    max_request_line_bytes = 8 * 1024;
    max_request_header_bytes = 32 * 1024;
    max_request_headers = 256;
    max_request_body_bytes = Some Stream.default_max_bytes;
    max_response_header_bytes = 32 * 1024;
    max_response_headers = 256;
    max_trailer_bytes = 8 * 1024;
    max_trailers = 64;
  }

let default_timeouts =
  {
    request_header_timeout = Some (Eta.Duration.seconds 30);
    request_body_timeout = Some (Eta.Duration.seconds 30);
    response_write_timeout = Some (Eta.Duration.seconds 30);
    response_body_timeout = Some (Eta.Duration.seconds 30);
    idle_timeout = Some (Eta.Duration.seconds 60);
    handler_timeout = Some (Eta.Duration.seconds 30);
  }

let default =
  {
    limits = default_limits;
    timeouts = default_timeouts;
    unread_body_policy = Reset;
    enable_otel = true;
    emit_url_full = false;
  }

let require_positive field value =
  if value <= 0 then
    invalid_arg ("Eta_http.Server.Config." ^ field ^ " must be > 0")

let require_non_negative field value =
  if value < 0 then
    invalid_arg ("Eta_http.Server.Config." ^ field ^ " must be >= 0")

let require_positive_duration field value =
  if Eta.Duration.is_zero value then
    invalid_arg ("Eta_http.Server.Config." ^ field ^ " must be > 0")

let validate_limits limits =
  require_positive "max_request_line_bytes" limits.max_request_line_bytes;
  require_positive "max_request_header_bytes" limits.max_request_header_bytes;
  require_positive "max_request_headers" limits.max_request_headers;
  Option.iter
    (require_non_negative "max_request_body_bytes")
    limits.max_request_body_bytes;
  require_positive "max_response_header_bytes" limits.max_response_header_bytes;
  require_positive "max_response_headers" limits.max_response_headers;
  require_positive "max_trailer_bytes" limits.max_trailer_bytes;
  require_positive "max_trailers" limits.max_trailers

let validate_unread_body_policy = function
  | Reset -> ()
  | Drain_up_to limit -> require_non_negative "Drain_up_to" limit

let validate_timeouts timeouts =
  Option.iter
    (require_positive_duration "request_header_timeout")
    timeouts.request_header_timeout;
  Option.iter
    (require_positive_duration "request_body_timeout")
    timeouts.request_body_timeout;
  Option.iter
    (require_positive_duration "response_write_timeout")
    timeouts.response_write_timeout;
  Option.iter
    (require_positive_duration "response_body_timeout")
    timeouts.response_body_timeout;
  Option.iter (require_positive_duration "idle_timeout")
    timeouts.idle_timeout;
  Option.iter (require_positive_duration "handler_timeout")
    timeouts.handler_timeout

let validate t =
  validate_limits t.limits;
  validate_unread_body_policy t.unread_body_policy;
  validate_timeouts t.timeouts
