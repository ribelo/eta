(** HTTP/1.x request-head parser.

    The parser works over a caller-owned buffer and returns spans into that
    buffer. Converting spans to strings is explicit and allocates. *)

type parse_error =
  | Partial
  | Invalid_method of string
  | Invalid_target of string
  | Invalid_version
  | Invalid_request_line
  | Invalid_header of string
  | Request_line_too_large of { limit : int }
  | Header_section_too_large of { limit : int }
  | Headers_too_many of { limit : int }

type header = {
  name : Span.t;
  value : Span.t;
}

type request = {
  method_ : Span.t;
  target : Span.t;
  version : Version.t;
  headers : header list;
  body_off : int;
}

val pp_parse_error : Format.formatter -> parse_error -> unit
val parse_error_to_string : parse_error -> string

val parse :
  ?max_request_line_bytes:int ->
  ?max_header_bytes:int ->
  ?max_headers:int ->
  bytes ->
  len:int ->
  (request, parse_error) result

val span_to_string : bytes -> Span.t -> string
val method_to_string : bytes -> request -> string
val target_to_string : bytes -> request -> string
val header_name : bytes -> header -> string
val header_value : bytes -> header -> string
val headers_to_list : bytes -> header list -> (string * string) list
