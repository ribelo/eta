(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

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

let pp_parse_error fmt = function
  | Partial -> Format.pp_print_string fmt "partial HTTP request"
  | Invalid_method method_ ->
      Format.fprintf fmt "invalid HTTP request method %S" method_
  | Invalid_target target ->
      Format.fprintf fmt "invalid HTTP request target %S" target
  | Invalid_version -> Format.pp_print_string fmt "invalid HTTP request version"
  | Invalid_request_line ->
      Format.pp_print_string fmt "invalid HTTP request line"
  | Invalid_header header -> Format.fprintf fmt "invalid HTTP header %S" header
  | Request_line_too_large { limit } ->
      Format.fprintf fmt "HTTP request line exceeds %d bytes" limit
  | Header_section_too_large { limit } ->
      Format.fprintf fmt "HTTP request header section exceeds %d bytes" limit
  | Headers_too_many { limit } ->
      Format.fprintf fmt "HTTP request header count exceeds %d" limit

let parse_error_to_string error = Format.asprintf "%a" pp_parse_error error

let span_to_string buf span =
  Bytes.sub_string buf span.Span.off span.len

let is_tchar = function
  | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_'
  | '`' | '|' | '~'
  | '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z' ->
      true
  | _ -> false

let is_ows = function ' ' | '\t' -> true | _ -> false

let invalid_header_value_char c =
  let code = Char.code c in
  (code < 32 && code <> 9) || code = 127

let invalid_target_char c =
  let code = Char.code c in
  code <= 32 || code = 127

let rec find_crlf buf index limit =
  if index + 1 >= limit then -1
  else if Char.equal (Bytes.unsafe_get buf index) '\r'
          && Char.equal (Bytes.unsafe_get buf (index + 1)) '\n'
  then index
  else find_crlf buf (index + 1) limit

let rec find_bare_cr buf index limit =
  if index >= limit then -1
  else if Char.equal (Bytes.unsafe_get buf index) '\r' then
    if index + 1 >= limit then -1
    else if Char.equal (Bytes.unsafe_get buf (index + 1)) '\n' then
      find_bare_cr buf (index + 2) limit
    else index
  else find_bare_cr buf (index + 1) limit

let rec find_char buf index limit char =
  if index >= limit then -1
  else if Char.equal (Bytes.unsafe_get buf index) char then index
  else find_char buf (index + 1) limit char

let rec validate_method buf index limit =
  index < limit
  && is_tchar (Bytes.unsafe_get buf index)
  && (index + 1 = limit || validate_method buf (index + 1) limit)

let rec validate_target buf index limit =
  index < limit
  && (not (invalid_target_char (Bytes.unsafe_get buf index)))
  && (index + 1 = limit || validate_target buf (index + 1) limit)

let rec validate_header_name buf index limit =
  index < limit
  && is_tchar (Bytes.unsafe_get buf index)
  && (index + 1 = limit || validate_header_name buf (index + 1) limit)

let rec validate_header_value buf index limit =
  index >= limit
  || ((not (invalid_header_value_char (Bytes.unsafe_get buf index)))
      && validate_header_value buf (index + 1) limit)

let rec trim_left buf index limit =
  if index >= limit then limit
  else if is_ows (Bytes.unsafe_get buf index) then trim_left buf (index + 1) limit
  else index

let rec trim_right buf start index =
  if index <= start then start
  else if is_ows (Bytes.unsafe_get buf (index - 1)) then
    trim_right buf start (index - 1)
  else index

let parse_version buf start finish =
  if finish - start <> 8 then Error Invalid_version
  else if Char.equal (Bytes.unsafe_get buf start) 'H'
          && Char.equal (Bytes.unsafe_get buf (start + 1)) 'T'
          && Char.equal (Bytes.unsafe_get buf (start + 2)) 'T'
          && Char.equal (Bytes.unsafe_get buf (start + 3)) 'P'
          && Char.equal (Bytes.unsafe_get buf (start + 4)) '/'
          && Char.equal (Bytes.unsafe_get buf (start + 5)) '1'
          && Char.equal (Bytes.unsafe_get buf (start + 6)) '.'
  then
    match Bytes.unsafe_get buf (start + 7) with
    | '0' -> Ok Version.H1_0
    | '1' -> Ok Version.H1_1
    | _ -> Error Invalid_version
  else Error Invalid_version

let parse_request_line buf line_end =
  let first_space = find_char buf 0 line_end ' ' in
  if first_space <= 0 then Error Invalid_request_line
  else
    let second_space = find_char buf (first_space + 1) line_end ' ' in
    if second_space <= first_space + 1 then
      Error
        (Invalid_target
           (Bytes.sub_string buf (first_space + 1)
              (max 0 (second_space - first_space - 1))))
    else if find_char buf (second_space + 1) line_end ' ' >= 0 then
      Error Invalid_request_line
    else if not (validate_method buf 0 first_space) then
      Error (Invalid_method (Bytes.sub_string buf 0 first_space))
    else if not (validate_target buf (first_space + 1) second_space) then
      Error
        (Invalid_target
           (Bytes.sub_string buf (first_space + 1)
              (second_space - first_space - 1)))
    else
      match parse_version buf (second_space + 1) line_end with
      | Error _ as error -> error
      | Ok version ->
          Ok
            ( Span.make ~off:0 ~len:first_space,
              Span.make ~off:(first_space + 1)
                ~len:(second_space - first_space - 1),
              version )

let parse_header buf line_start line_end =
  let colon = find_char buf line_start line_end ':' in
  if colon <= line_start then
    Error (Invalid_header (Bytes.sub_string buf line_start (line_end - line_start)))
  else if not (validate_header_name buf line_start colon) then
    Error (Invalid_header (Bytes.sub_string buf line_start (line_end - line_start)))
  else
    let value_start = trim_left buf (colon + 1) line_end in
    let value_end = trim_right buf value_start line_end in
    if not (validate_header_value buf value_start value_end) then
      Error
        (Invalid_header (Bytes.sub_string buf line_start (line_end - line_start)))
    else
      Ok
        {
          name = Span.make ~off:line_start ~len:(colon - line_start);
          value = Span.make ~off:value_start ~len:(value_end - value_start);
        }

let ensure_positive name value =
  if value <= 0 then invalid_arg ("Eta_http.H1.Request_parse.parse: " ^ name)

let parse ?(max_request_line_bytes = 8 * 1024)
    ?(max_header_bytes = 32 * 1024) ?(max_headers = 256) buf ~len =
  if len > Bytes.length buf then invalid_arg "Eta_http.H1.Request_parse.parse";
  ensure_positive "max_request_line_bytes must be > 0" max_request_line_bytes;
  ensure_positive "max_header_bytes must be > 0" max_header_bytes;
  ensure_positive "max_headers must be > 0" max_headers;
  let line_end = find_crlf buf 0 len in
  if line_end < 0 then
    if find_bare_cr buf 0 len >= 0 then Error Invalid_request_line
    else if len > max_request_line_bytes then
      Error (Request_line_too_large { limit = max_request_line_bytes })
    else Error Partial
  else if line_end + 2 > max_request_line_bytes then
    Error (Request_line_too_large { limit = max_request_line_bytes })
  else
    match parse_request_line buf line_end with
    | Error error -> Error error
    | Ok (method_, target, version) ->
        let headers_start = line_end + 2 in
        let rec parse_headers count line_start acc =
          if line_start + 1 >= len then
            if len - headers_start > max_header_bytes then
              Error (Header_section_too_large { limit = max_header_bytes })
            else Error Partial
          else if line_start - headers_start > max_header_bytes then
            Error (Header_section_too_large { limit = max_header_bytes })
          else if Char.equal (Bytes.unsafe_get buf line_start) '\r'
                  && Char.equal (Bytes.unsafe_get buf (line_start + 1)) '\n'
          then
            let section_len = line_start + 2 - headers_start in
            if section_len > max_header_bytes then
              Error (Header_section_too_large { limit = max_header_bytes })
            else
              Ok
                {
                  method_;
                  target;
                  version;
                  headers = List.rev acc;
                  body_off = line_start + 2;
                }
          else if count >= max_headers then
            Error (Headers_too_many { limit = max_headers })
          else
            let header_end = find_crlf buf line_start len in
            if header_end < 0 then
              if find_bare_cr buf line_start len >= 0 then
                Error
                  (Invalid_header
                     (Bytes.sub_string buf line_start (len - line_start)))
              else if len - headers_start > max_header_bytes then
                Error (Header_section_too_large { limit = max_header_bytes })
              else Error Partial
            else if header_end + 2 - headers_start > max_header_bytes then
              Error (Header_section_too_large { limit = max_header_bytes })
            else
              match parse_header buf line_start header_end with
              | Error error -> Error error
              | Ok header ->
                  parse_headers (count + 1) (header_end + 2) (header :: acc)
        in
        parse_headers 0 headers_start []

let method_to_string buf request = span_to_string buf request.method_
let target_to_string buf request = span_to_string buf request.target
let header_name buf header = span_to_string buf header.name
let header_value buf header = span_to_string buf header.value

let headers_to_list buf headers =
  List.map (fun header -> (header_name buf header, header_value buf header)) headers
