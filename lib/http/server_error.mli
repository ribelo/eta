(** Typed eta-http server errors. *)

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
  | Expectation_failed of { expectation : string }
  | Request_body_too_large of { limit : int; length : int }
  | Request_timeout of { timeout_ms : int option }
  | Stream_admission_rejected of { limit : int }
  | Stream_reset of { code : string; message : string }
  | Connection_closed of { during : layer }
  | Protocol_error of { kind : string; message : string }
  | Handler_timeout of { timeout_ms : int option }
  | Handler_failed of { message : string }
  | Response_body_timeout of { timeout_ms : int option }
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

val make :
  ?protocol:protocol ->
  ?stream_id:int ->
  method_:string ->
  target:string ->
  kind ->
  t

val protocol_to_string : protocol -> string
val layer_to_string : layer -> string
val kind_name : kind -> string
val layer : t -> layer
val error_class : t -> string
val to_status : t -> int option
val to_http_error : t -> Error.t
val pp : Format.formatter -> t -> unit
val to_string : t -> string
