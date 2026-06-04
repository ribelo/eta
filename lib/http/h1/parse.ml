(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

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

let pp_parse_error fmt = function
  | Partial -> Format.pp_print_string fmt "partial HTTP response"
  | Invalid_version -> Format.pp_print_string fmt "invalid HTTP response version"
  | Invalid_status status -> Format.fprintf fmt "invalid HTTP status %S" status
  | Invalid_status_line ->
      Format.pp_print_string fmt "invalid HTTP response status line"
  | Invalid_header header -> Format.fprintf fmt "invalid HTTP header %S" header
  | Invalid_content_length value ->
      Format.fprintf fmt "invalid Content-Length %S" value
  | Header_section_too_large { limit } ->
      Format.fprintf fmt "HTTP response header section exceeds %d bytes" limit
  | Body_too_large { limit; length } ->
      Format.fprintf fmt "HTTP response body length %d exceeds %d bytes" length
        limit
  | Body_truncated { expected; available } ->
      Format.fprintf fmt "HTTP response body truncated: expected %d available %d"
        expected available

let parse_error_to_string error = Format.asprintf "%a" pp_parse_error error

let span_to_string buf span =
  Bytes.sub_string buf span.Span.off span.len

let raw_ok = 0
let raw_partial = -1
let raw_invalid_version = -2
let raw_invalid_status = -3
let raw_invalid_status_line = -4
let raw_invalid_header = -5
let raw_invalid_content_length = -6
let raw_header_section_too_large = -7
let raw_body_truncated = -8

type raw_headers = {
  name_offs : int array;
  name_lens : int array;
  value_offs : int array;
  value_lens : int array;
}

type raw_response = {
  mutable version_code : int;
  mutable status_code : int;
  mutable reason_off : int;
  mutable reason_len : int;
  mutable header_count : int;
  mutable body_off : int;
  mutable body_len : int;
  mutable content_length : int;
  mutable content_length_off : int;
  mutable content_length_len : int;
  mutable error_off : int;
  mutable error_len : int;
  mutable error_expected : int;
  mutable error_available : int;
}

let create_raw_headers capacity =
  if capacity <= 0 then invalid_arg "Eta_http.H1.Parse.create_raw_headers";
  {
    name_offs = Array.make capacity 0;
    name_lens = Array.make capacity 0;
    value_offs = Array.make capacity 0;
    value_lens = Array.make capacity 0;
  }

let create_raw_response () =
  {
    version_code = 0;
    status_code = 0;
    reason_off = 0;
    reason_len = 0;
    header_count = 0;
    body_off = 0;
    body_len = 0;
    content_length = -1;
    content_length_off = 0;
    content_length_len = 0;
    error_off = 0;
    error_len = 0;
    error_expected = 0;
    error_available = 0;
  }

let[@zero_alloc] reset_raw raw =
  raw.version_code <- 0;
  raw.status_code <- 0;
  raw.reason_off <- 0;
  raw.reason_len <- 0;
  raw.header_count <- 0;
  raw.body_off <- 0;
  raw.body_len <- 0;
  raw.content_length <- -1;
  raw.content_length_off <- 0;
  raw.content_length_len <- 0;
  raw.error_off <- 0;
  raw.error_len <- 0;
  raw.error_expected <- 0;
  raw.error_available <- 0

let[@zero_alloc] lowercase_ascii_raw c =
  match c with 'A' .. 'Z' -> Char.chr (Char.code c + 32) | _ -> c

let[@zero_alloc] raw_is_tchar = function
  | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_'
  | '`' | '|' | '~'
  | '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z' ->
      true
  | _ -> false

let[@zero_alloc] raw_is_ows = function ' ' | '\t' -> true | _ -> false

let[@zero_alloc] rec raw_find_crlf buf index limit =
  if index + 1 >= limit then -1
  else if Char.equal (Bytes.unsafe_get buf index) '\r'
          && Char.equal (Bytes.unsafe_get buf (index + 1)) '\n'
  then index
  else raw_find_crlf buf (index + 1) limit

let[@zero_alloc] rec raw_find_colon buf index limit =
  if index >= limit then -1
  else if Char.equal (Bytes.unsafe_get buf index) ':' then index
  else raw_find_colon buf (index + 1) limit

let[@zero_alloc] rec raw_validate_header_name buf index limit =
  index >= limit
  || (raw_is_tchar (Bytes.unsafe_get buf index)
      && raw_validate_header_name buf (index + 1) limit)

let[@zero_alloc] rec raw_trim_left buf index limit =
  if index >= limit then limit
  else if raw_is_ows (Bytes.unsafe_get buf index) then
    raw_trim_left buf (index + 1) limit
  else index

let[@zero_alloc] rec raw_trim_right buf start index =
  if index <= start then start
  else if raw_is_ows (Bytes.unsafe_get buf (index - 1)) then
    raw_trim_right buf start (index - 1)
  else index

let[@zero_alloc] rec raw_header_name_eq_literal_loop buf off literal len index =
  index = len
  || (Char.equal
        (lowercase_ascii_raw (Bytes.unsafe_get buf (off + index)))
        (String.unsafe_get literal index)
      && raw_header_name_eq_literal_loop buf off literal len (index + 1))

let[@zero_alloc] raw_header_name_eq_literal buf off len literal =
  let literal_len = String.length literal in
  len = literal_len && raw_header_name_eq_literal_loop buf off literal len 0

let[@zero_alloc] rec raw_span_equal buf left_off right_off len index =
  index = len
  || (Char.equal
        (Bytes.unsafe_get buf (left_off + index))
        (Bytes.unsafe_get buf (right_off + index))
      && raw_span_equal buf left_off right_off len (index + 1))

let[@zero_alloc] raw_set_error raw code off len =
  raw.error_off <- off;
  raw.error_len <- len;
  code

let[@zero_alloc] raw_set_body_truncated raw expected available =
  raw.error_expected <- expected;
  raw.error_available <- available;
  raw_body_truncated

let[@zero_alloc] raw_parse_version buf raw =
  if Char.equal (Bytes.unsafe_get buf 0) 'H'
     && Char.equal (Bytes.unsafe_get buf 1) 'T'
     && Char.equal (Bytes.unsafe_get buf 2) 'T'
     && Char.equal (Bytes.unsafe_get buf 3) 'P'
     && Char.equal (Bytes.unsafe_get buf 4) '/'
     && Char.equal (Bytes.unsafe_get buf 5) '1'
     && Char.equal (Bytes.unsafe_get buf 6) '.'
  then
    match Bytes.unsafe_get buf 7 with
    | '0' ->
        raw.version_code <- 10;
        raw_ok
    | '1' ->
        raw.version_code <- 11;
        raw_ok
    | _ -> raw_invalid_version
  else raw_invalid_version

let[@zero_alloc] raw_digit buf index =
  match Bytes.unsafe_get buf index with
  | '0' .. '9' as c -> Char.code c - Char.code '0'
  | _ -> -1

let[@zero_alloc] raw_parse_status buf raw =
  let d0 = raw_digit buf 9 in
  let d1 = raw_digit buf 10 in
  let d2 = raw_digit buf 11 in
  if d0 < 0 || d1 < 0 || d2 < 0 then
    raw_set_error raw raw_invalid_status 9 3
  else
    let status = (d0 * 100) + (d1 * 10) + d2 in
    if status < 100 || status > 599 then
      raw_set_error raw raw_invalid_status 9 3
    else (
      raw.status_code <- status;
      raw_ok)

let[@zero_alloc] raw_parse_status_line buf line_end raw =
  if line_end < 12 then raw_invalid_status_line
  else
    let version = raw_parse_version buf raw in
    if version < 0 then version
    else if not (Char.equal (Bytes.unsafe_get buf 8) ' ') then
      raw_invalid_status_line
    else
      let status = raw_parse_status buf raw in
      if status < 0 then status
      else if line_end = 12 then (
        raw.reason_off <- 0;
        raw.reason_len <- 0;
        raw_ok)
      else if Char.equal (Bytes.unsafe_get buf 12) ' ' then (
        raw.reason_off <- 13;
        raw.reason_len <- line_end - 13;
        raw_ok)
      else raw_invalid_status_line

let[@zero_alloc] rec raw_parse_digits buf index finish acc =
  if index >= finish then acc
  else
    let digit = raw_digit buf index in
    if digit < 0 then -1
    else
      let next = (acc * 10) + digit in
      if next < acc then -1 else raw_parse_digits buf (index + 1) finish next

let[@zero_alloc] raw_parse_content_length buf raw value_start value_end =
  let len = value_end - value_start in
  if len = 0 then
    raw_set_error raw raw_invalid_content_length value_start len
  else if raw.content_length_len > 0 then
    if raw.content_length_len <> len
       || not
            (raw_span_equal buf raw.content_length_off value_start len 0)
    then raw_set_error raw raw_invalid_content_length value_start len
    else raw_ok
  else
    let parsed = raw_parse_digits buf value_start value_end 0 in
    if parsed < 0 then
      raw_set_error raw raw_invalid_content_length value_start len
    else (
      raw.content_length <- parsed;
      raw.content_length_off <- value_start;
      raw.content_length_len <- len;
      raw_ok)

let[@zero_alloc] raw_store_header headers count name_off name_len value_off value_len =
  Array.unsafe_set headers.name_offs count name_off;
  Array.unsafe_set headers.name_lens count name_len;
  Array.unsafe_set headers.value_offs count value_off;
  Array.unsafe_set headers.value_lens count value_len

let[@zero_alloc] raw_parse_header buf headers raw count line_start line_end =
  if count >= Array.length headers.name_offs then raw_header_section_too_large
  else
    let colon = raw_find_colon buf line_start line_end in
    if colon <= line_start then
      raw_set_error raw raw_invalid_header line_start (line_end - line_start)
    else if not (raw_validate_header_name buf line_start colon) then
      raw_set_error raw raw_invalid_header line_start (line_end - line_start)
    else
      let value_start = raw_trim_left buf (colon + 1) line_end in
      let value_end = raw_trim_right buf value_start line_end in
      let name_len = colon - line_start in
      let value_len = value_end - value_start in
      raw_store_header headers count line_start name_len value_start value_len;
      if
        raw_header_name_eq_literal buf line_start name_len "content-length"
      then raw_parse_content_length buf raw value_start value_end
      else raw_ok

let rec raw_headers_to_list_loop buf headers index acc =
  if index < 0 then acc
  else
    let name =
      Bytes.sub_string buf
        (Array.unsafe_get headers.name_offs index)
        (Array.unsafe_get headers.name_lens index)
    in
    let value =
      Bytes.sub_string buf
        (Array.unsafe_get headers.value_offs index)
        (Array.unsafe_get headers.value_lens index)
    in
    raw_headers_to_list_loop buf headers (index - 1) ((name, value) :: acc)

let raw_headers_to_list buf headers raw =
  raw_headers_to_list_loop buf headers (raw.header_count - 1) []

let raw_status raw = raw.status_code
let raw_body_off raw = raw.body_off
let raw_body_len raw = raw.body_len

let raw_content_length raw =
  if raw.content_length < 0 then None else Some raw.content_length

let raw_error buf raw ~max_header_bytes = function
  | code when code = raw_partial -> Partial
  | code when code = raw_invalid_version -> Invalid_version
  | code when code = raw_invalid_status ->
      Invalid_status (Bytes.sub_string buf raw.error_off raw.error_len)
  | code when code = raw_invalid_status_line -> Invalid_status_line
  | code when code = raw_invalid_header ->
      Invalid_header (Bytes.sub_string buf raw.error_off raw.error_len)
  | code when code = raw_invalid_content_length ->
      Invalid_content_length (Bytes.sub_string buf raw.error_off raw.error_len)
  | code when code = raw_header_section_too_large ->
      Header_section_too_large { limit = max_header_bytes }
  | code when code = raw_body_truncated ->
      Body_truncated
        { expected = raw.error_expected; available = raw.error_available }
  | code -> Invalid_header (string_of_int code)

let[@zero_alloc] rec parse_raw_headers buf len max_header_bytes headers raw
    count line_start =
  if line_start + 1 >= len then raw_partial
  else if line_start > max_header_bytes then raw_header_section_too_large
  else if Char.equal (Bytes.unsafe_get buf line_start) '\r'
          && Char.equal (Bytes.unsafe_get buf (line_start + 1)) '\n'
  then (
    let body_start = line_start + 2 in
    let available = len - body_start in
    let body_len =
      if raw.content_length < 0 then available else raw.content_length
    in
    raw.header_count <- count;
    raw.body_off <- body_start;
    raw.body_len <- body_len;
    if body_len > available then
      raw_set_body_truncated raw body_len available
    else raw_ok)
  else
    let line_end = raw_find_crlf buf line_start len in
    if line_end < 0 then raw_partial
    else if line_end + 2 > max_header_bytes then raw_header_section_too_large
    else
      let header = raw_parse_header buf headers raw count line_start line_end in
      if header < 0 then header
      else
        parse_raw_headers buf len max_header_bytes headers raw (count + 1)
          (line_end + 2)

let[@zero_alloc] parse_raw buf ~len ~max_header_bytes ~headers raw =
  if len > Bytes.length buf then invalid_arg "Eta_http.H1.Parse.parse_raw";
  reset_raw raw;
  let status_line_end = raw_find_crlf buf 0 len in
  if status_line_end < 0 then raw_partial
  else if status_line_end + 2 > max_header_bytes then
    raw_header_section_too_large
  else
    let status = raw_parse_status_line buf status_line_end raw in
    if status < 0 then status
    else
      parse_raw_headers buf len max_header_bytes headers raw 0
        (status_line_end + 2)

let header_name buf header = span_to_string buf header.name
let header_value buf header = span_to_string buf header.value

let headers_to_list buf headers =
  List.map (fun header -> (header_name buf header, header_value buf header)) headers

let header_of_raw headers index =
  {
    name =
      Span.make
        ~off:(Array.unsafe_get headers.name_offs index)
        ~len:(Array.unsafe_get headers.name_lens index);
    value =
      Span.make
        ~off:(Array.unsafe_get headers.value_offs index)
        ~len:(Array.unsafe_get headers.value_lens index);
  }

let raw_version raw =
  match raw.version_code with
  | 10 -> Version.H1_0
  | 11 -> Version.H1_1
  | _ -> Version.H1_1

let response_of_raw headers raw =
  let rec build index acc =
    if index < 0 then acc
    else build (index - 1) (header_of_raw headers index :: acc)
  in
  {
    version = raw_version raw;
    status = raw.status_code;
    reason =
      Span.make ~off:raw.reason_off ~len:raw.reason_len;
    headers = build (raw.header_count - 1) [];
    body = Span.make ~off:raw.body_off ~len:raw.body_len;
  }

let parse_with_capacity ~max_header_bytes buf ~len capacity =
  let headers = create_raw_headers capacity in
  let raw = create_raw_response () in
  match parse_raw buf ~len ~max_header_bytes ~headers raw with
  | code when code = raw_ok -> `Ok (response_of_raw headers raw)
  | code when code = raw_header_section_too_large -> `Header_section_too_large
  | code -> `Error (raw_error buf raw ~max_header_bytes code)

let parse ?(max_header_bytes = 32 * 1024) buf ~len =
  match parse_with_capacity ~max_header_bytes buf ~len 16 with
  | `Ok response -> Ok response
  | `Error error -> Error error
  | `Header_section_too_large -> (
      match parse_with_capacity ~max_header_bytes buf ~len 256 with
      | `Ok response -> Ok response
      | `Error error -> Error error
      | `Header_section_too_large ->
          Error (Header_section_too_large { limit = max_header_bytes }))

let body_to_bytes buf response =
  Bytes.sub buf response.body.off response.body.len
