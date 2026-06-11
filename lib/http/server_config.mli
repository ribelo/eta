(** Backend-neutral HTTP server configuration.

    These values describe HTTP semantics that every server backend must honor.
    Runtime adapters keep transport-owned knobs, such as socket backlog and
    read-buffer sizing, in their own configuration records. *)

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

val default_limits : limits
val default_timeouts : timeouts
val default : t
val validate : t -> unit
