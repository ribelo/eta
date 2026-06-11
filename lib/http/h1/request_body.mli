(** HTTP/1.x request body framing decisions. *)

type framing =
  | No_body
  | Fixed of int
  | Chunked

type error =
  | Invalid_content_length of string
  | Conflicting_content_length of {
      first : string;
      second : string;
    }
  | Content_length_with_transfer_encoding
  | Unsupported_transfer_encoding of string list

val pp_error : Format.formatter -> error -> unit
val error_to_string : error -> string

val of_headers : Header.t -> (framing, error) result
(** Classify request body framing from validated request headers.

    The accepted forms are no body, fixed [Content-Length], and a single final
    [Transfer-Encoding: chunked]. Any [Content-Length] combined with
    [Transfer-Encoding] is rejected before a body reader is selected. *)
