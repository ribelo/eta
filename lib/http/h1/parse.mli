(** HTTP/1.x response parser.

    The parser works over a caller-owned buffer and returns spans into that
    buffer. Converting spans to strings is explicit and allocates. *)

type parse_error : immutable_data =
  | Partial
  | Invalid_version
  | Invalid_status of string
  | Invalid_status_line
  | Invalid_header of string
  | Invalid_content_length of string
  | Header_section_too_large of { limit : int }
  | Body_too_large of { limit : int; length : int }
  | Body_truncated of { expected : int; available : int }

type header : immutable_data = {
  name : Span.t;
  value : Span.t;
}

type response : immutable_data = {
  version : Version.t;
  status : int;
  reason : Span.t;
  headers : header list;
  body : Span.t;
}

val pp_parse_error : Format.formatter -> parse_error -> unit
val parse_error_to_string : parse_error -> string

val raw_ok : int
val raw_partial : int
val raw_invalid_version : int
val raw_invalid_status : int
val raw_invalid_status_line : int
val raw_invalid_header : int
val raw_invalid_content_length : int
val raw_header_section_too_large : int
val raw_body_truncated : int

type raw_headers
type raw_response

val create_raw_headers : int -> raw_headers
val create_raw_response : unit -> raw_response

val[@zero_alloc] parse_raw :
  bytes ->
  len:int ->
  max_header_bytes:int ->
  headers:raw_headers ->
  raw_response ->
  int
(** Low-level parser core for allocation probes.

    [parse_raw] writes spans and parsed metadata into caller-owned state and
    returns one of the [raw_*] integer codes. It does not allocate on the
    success path. Use {!parse} when typed errors and allocated public records
    are needed. *)

val raw_error :
  bytes -> raw_response -> max_header_bytes:int -> int -> parse_error
val raw_headers_to_list :
  bytes -> raw_headers -> raw_response -> (string * string) list
val raw_status : raw_response -> int
val raw_content_length : raw_response -> int option
val raw_body_off : raw_response -> int
val raw_body_len : raw_response -> int

val parse :
  ?max_header_bytes:int -> bytes -> len:int -> (response, parse_error) result

val span_to_string : bytes -> Span.t -> string
val header_name : bytes -> header -> string
val header_value : bytes -> header -> string
val headers_to_list : bytes -> header list -> (string * string) list
val body_to_bytes : bytes -> response -> bytes
