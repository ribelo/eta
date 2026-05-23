(** Byte-level HTTP/2 security envelope checks.

    This scanner observes raw server-to-client frame bytes before they are
    handed to [ocaml-h2]. It owns eta-http's cheap frame-envelope policy:
    SETTINGS churn, GOAWAY churn, response-header churn, and
    header-block/CONTINUATION accumulator caps. HPACK decoding remains owned by
    [ocaml-h2]. *)

type config = {
  max_settings_per_connection : int;
  max_goaway_per_connection : int;
  max_hpack_block_bytes : int;
  max_continuation_accumulator_bytes : int;
  max_response_headers_per_connection : int;
  max_header_name_bytes : int;
  max_header_value_bytes : int;
}

val default_config : config

type t

val create : ?config:config -> unit -> t

val observe :
  t ->
  Bigstringaf.t ->
  off:int ->
  len:int ->
  Eta_http_error.Error.kind option

val validate_headers : (string * string) list -> Eta_http_error.Error.kind option
