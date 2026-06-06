(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type body = Empty | Fixed of bytes list

let buffer_too_small = -1
let invalid_method = -2
let invalid_header = -3
let invalid_framing = -4
let invalid_transfer_encoding = -5

let invalid_framing_reason =
  "invalid request framing: Content-Length must match body length and not "
  ^ "conflict with Transfer-Encoding"

let invalid_transfer_encoding_reason =
  "invalid request framing: Transfer-Encoding cannot be used with a fixed body "
  ^ "writer"

let content_length = function
  | Empty -> None
  | Fixed chunks ->
      Some
        (List.fold_left
           (fun total chunk -> total + Bytes.length chunk)
           0 chunks)

let add_header_line buffer (name, value) =
  Buffer.add_string buffer name;
  Buffer.add_string buffer ": ";
  Buffer.add_string buffer value;
  Buffer.add_string buffer "\r\n"

let write_string flow value = Eio.Flow.copy_string value flow

let write_bytes flow bytes =
  Eio.Flow.copy_string (Bytes.to_string bytes) flow

let write_header_line flow (name, value) =
  write_string flow name;
  write_string flow ": ";
  write_string flow value;
  write_string flow "\r\n"

let has_header name headers =
  Option.is_some (Header.get name headers)

let[@zero_alloc] lowercase_ascii c =
  match c with 'A' .. 'Z' -> Char.chr (Char.code c + 32) | _ -> c

let[@zero_alloc] rec equal_header_name_loop normalized candidate len index =
  index = len
  || (Char.equal
        (lowercase_ascii (String.unsafe_get candidate index))
        (String.unsafe_get normalized index)
      && equal_header_name_loop normalized candidate len (index + 1))

let[@zero_alloc] equal_header_name normalized candidate =
  let len = String.length normalized in
  String.length candidate = len
  && equal_header_name_loop normalized candidate len 0

let[@zero_alloc] rec has_header_raw normalized = function
  | [] -> false
  | (name, _) :: rest -> equal_header_name normalized name || has_header_raw normalized rest

let[@zero_alloc] is_ows = function ' ' | '\t' -> true | _ -> false

let[@zero_alloc] rec first_non_ows value len index =
  if index >= len then len
  else if is_ows (String.unsafe_get value index) then
    first_non_ows value len (index + 1)
  else index

let[@zero_alloc] rec last_non_ows value index =
  if index < 0 then -1
  else if is_ows (String.unsafe_get value index) then
    last_non_ows value (index - 1)
  else index

let[@zero_alloc] digit = function
  | '0' .. '9' as c -> Char.code c - Char.code '0'
  | _ -> -1

let[@zero_alloc] rec parse_content_length_digits value index finish acc =
  if index >= finish then acc
  else
    let digit = digit (String.unsafe_get value index) in
    if digit < 0 then -1
    else if acc > max_int / 10 || (acc = max_int / 10 && digit > max_int mod 10)
    then -1
    else parse_content_length_digits value (index + 1) finish ((acc * 10) + digit)

let[@zero_alloc] parse_content_length_value value =
  let len = String.length value in
  let first = first_non_ows value len 0 in
  let last = last_non_ows value (len - 1) in
  if first > last then -1
  else parse_content_length_digits value first (last + 1) 0

let[@zero_alloc] rec content_length_header_raw current = function
  | [] -> current
  | (name, value) :: rest ->
      if equal_header_name "content-length" name then
        let parsed = parse_content_length_value value in
        if parsed < 0 then invalid_framing
        else if current < 0 then content_length_header_raw parsed rest
        else if parsed = current then content_length_header_raw current rest
        else invalid_framing
      else content_length_header_raw current rest

let[@zero_alloc] validate_framing_raw ~fixed_body ~body_length headers =
  let caller_content_length = content_length_header_raw (-1) headers in
  let transfer_encoding = has_header_raw "transfer-encoding" headers in
  if caller_content_length < -1 then invalid_framing
  else if caller_content_length >= 0 && transfer_encoding then invalid_framing
  else if fixed_body && transfer_encoding then invalid_transfer_encoding
  else if body_length >= 0 && caller_content_length >= 0
          && caller_content_length <> body_length
  then invalid_framing
  else 0

let[@zero_alloc] rec validate_method_loop method_ len index =
  if index = len then true
  else
    match String.unsafe_get method_ index with
    | 'A' .. 'Z' | '0' .. '9' | '!' | '#' | '$' | '%' | '&' | '\'' | '*'
    | '+' | '-' | '.' | '^' | '_' | '`' | '|' | '~' ->
        validate_method_loop method_ len (index + 1)
    | _ -> false

let[@zero_alloc] validate_method method_ =
  let len = String.length method_ in
  len > 0 && validate_method_loop method_ len 0

let[@zero_alloc] blit_literal dst pos value =
  let len = String.length value in
  if pos >= 0 && pos <= Bytes.length dst - len then (
    Bytes.blit_string value 0 dst pos len;
    pos + len)
  else buffer_too_small

let[@zero_alloc] blit_bytes dst pos value =
  let len = Bytes.length value in
  if pos >= 0 && pos <= Bytes.length dst - len then (
    Bytes.blit value 0 dst pos len;
    pos + len)
  else buffer_too_small

let[@zero_alloc] rec decimal_digits_loop digits n =
  if n < 10 then digits else decimal_digits_loop (digits + 1) (n / 10)

let[@zero_alloc] decimal_digits value = decimal_digits_loop 1 value

let[@zero_alloc] rec blit_int_loop dst pos index value =
  if index < 0 then ()
  else
    let digit = value mod 10 in
    Bytes.unsafe_set dst (pos + index) (Char.chr (Char.code '0' + digit));
    blit_int_loop dst pos (index - 1) (value / 10)

let[@zero_alloc] blit_int dst pos value =
  if value < 0 then buffer_too_small
  else
    let digits = decimal_digits value in
    if pos < 0 || pos > Bytes.length dst - digits then buffer_too_small
    else (
      blit_int_loop dst pos (digits - 1) value;
      pos + digits)

let[@zero_alloc] rec content_length_chunks total = function
  | [] -> total
  | chunk :: rest -> content_length_chunks (total + Bytes.length chunk) rest

let[@zero_alloc] content_length_raw = function
  | Empty -> -1
  | Fixed chunks -> content_length_chunks 0 chunks

let[@zero_alloc] framing_body_length_raw = function
  | Empty -> 0
  | Fixed chunks -> content_length_chunks 0 chunks

let[@zero_alloc] fixed_body_raw = function Empty -> false | Fixed _ -> true

let[@zero_alloc] blit_header_line dst pos name value =
  let pos = blit_literal dst pos name in
  let pos = blit_literal dst pos ": " in
  let pos = blit_literal dst pos value in
  blit_literal dst pos "\r\n"

let[@zero_alloc] rec blit_headers_reverse dst pos = function
  | [] -> pos
  | (name, value) :: rest ->
      let pos = blit_headers_reverse dst pos rest in
      if pos < 0 then pos else blit_header_line dst pos name value

let[@zero_alloc] rec blit_body dst pos = function
  | [] -> pos
  | chunk :: rest ->
      let pos = blit_bytes dst pos chunk in
      if pos < 0 then pos else blit_body dst pos rest

let[@zero_alloc] write_to_bytes_raw dst ~pos ~method_ ~url ~headers ~body =
  if not (validate_method method_) then invalid_method
  else if not (Header.valid headers) then invalid_header
  else
    let framing =
      validate_framing_raw ~fixed_body:(fixed_body_raw body)
        ~body_length:(framing_body_length_raw body) headers
    in
    if framing < 0 then framing
    else
    let pos = blit_literal dst pos method_ in
    let pos = blit_literal dst pos " " in
    let pos = Url.blit_origin_form_raw dst pos url in
    let pos = blit_literal dst pos " HTTP/1.1\r\n" in
    let pos =
      if has_header_raw "host" headers then pos
      else
        let pos = blit_literal dst pos "Host: " in
        let pos = Url.blit_authority_raw dst pos url in
        blit_literal dst pos "\r\n"
    in
    let pos =
      if has_header_raw "connection" headers then pos
      else blit_header_line dst pos "Connection" "keep-alive"
    in
    let length = content_length_raw body in
    let pos =
      if length < 0 || has_header_raw "content-length" headers then pos
      else
        let pos = blit_literal dst pos "Content-Length: " in
        let pos = blit_int dst pos length in
        blit_literal dst pos "\r\n"
    in
    let pos = blit_headers_reverse dst pos headers in
    let pos = blit_literal dst pos "\r\n" in
    match body with Empty -> pos | Fixed chunks -> blit_body dst pos chunks

let write_to_bytes dst ~pos ~method_ ~url ~headers ~body =
  match write_to_bytes_raw dst ~pos ~method_ ~url ~headers ~body with
  | n when n >= 0 -> Ok n
  | n when n = invalid_method ->
      Error
        (Error.make ~method_ ~uri:(Url.to_string url)
           (Header_invalid { reason = "invalid request method" }))
  | n when n = invalid_header ->
      Error
        (Error.make ~method_ ~uri:(Url.to_string url)
           (Header_invalid { reason = "invalid request header" }))
  | n when n = invalid_framing ->
      Error
        (Error.make ~method_ ~uri:(Url.to_string url)
           (Header_invalid { reason = invalid_framing_reason }))
  | n when n = invalid_transfer_encoding ->
      Error
        (Error.make ~method_ ~uri:(Url.to_string url)
           (Header_invalid { reason = invalid_transfer_encoding_reason }))
  | _ ->
      Error
        (Error.make ~method_ ~uri:(Url.to_string url)
           (Header_invalid { reason = "request buffer too small" }))

let validate_headers ~method_ ~url headers =
  match Header.validate headers with
  | None -> Ok ()
  | Some kind ->
      Error
        (Error.make ~method_
           ~uri:(Url.to_string url)
           kind)

let fixed_body = function Empty -> false | Fixed _ -> true

let validate_request_framing ~body ~body_length ~method_ ~url ~headers =
  match
    validate_framing_raw ~fixed_body:(fixed_body body) ~body_length headers
  with
  | 0 -> Ok ()
  | n when n = invalid_transfer_encoding ->
      Error
        (Error.make ~method_ ~uri:(Url.to_string url)
           (Header_invalid { reason = invalid_transfer_encoding_reason }))
  | _ ->
      Error
        (Error.make ~method_ ~uri:(Url.to_string url)
           (Header_invalid { reason = invalid_framing_reason }))

let resolved_framing_body_length ?framing_body_length body =
  match body with
  | Fixed _ -> framing_body_length_raw body
  | Empty -> (
      match framing_body_length with
      | None -> framing_body_length_raw body
      | Some length -> length)

let flow_write_error ~method_ ~url =
  Error.make ~protocol:H1 ~method_
    ~uri:(Url.to_string url)
    (Connection_closed { during = Http_request })

let write ?framing_body_length buffer ~method_ ~url ~headers ~body =
  if not (validate_method method_) then
    Error
      (Error.make ~method_ ~uri:(Url.to_string url)
         (Header_invalid { reason = "invalid request method" }))
  else
    match validate_headers ~method_ ~url headers with
    | Error _ as error -> error
    | Ok () ->
        (match
           validate_request_framing
             ~body
             ~body_length:(resolved_framing_body_length ?framing_body_length body)
             ~method_ ~url ~headers
         with
        | Error _ as error -> error
        | Ok () ->
        Buffer.add_string buffer method_;
        Buffer.add_char buffer ' ';
        Buffer.add_string buffer (Url.origin_form url);
        Buffer.add_string buffer " HTTP/1.1\r\n";
        if not (has_header "host" headers) then
          add_header_line buffer ("Host", Url.authority url);
        if not (has_header "connection" headers) then
          add_header_line buffer ("Connection", "keep-alive");
        (match content_length body with
        | None -> ()
        | Some length ->
            if not (has_header "content-length" headers) then
              add_header_line buffer ("Content-Length", string_of_int length));
        List.iter (add_header_line buffer) (List.rev headers);
        Buffer.add_string buffer "\r\n";
        (match body with
        | Empty -> ()
        | Fixed chunks -> List.iter (fun chunk -> Buffer.add_bytes buffer chunk) chunks);
        Ok ())

let write_to_flow ?framing_body_length flow ~method_ ~url ~headers ~body =
  if not (validate_method method_) then
    Error
      (Error.make ~method_ ~uri:(Url.to_string url)
         (Header_invalid { reason = "invalid request method" }))
  else
    match validate_headers ~method_ ~url headers with
    | Error _ as error -> error
    | Ok () ->
        (match
           validate_request_framing
             ~body
             ~body_length:(resolved_framing_body_length ?framing_body_length body)
             ~method_ ~url ~headers
         with
        | Error _ as error -> error
        | Ok () ->
        let buf = Buffer.create 512 in
        (try
           Buffer.add_string buf method_;
           Buffer.add_char buf ' ';
           Buffer.add_string buf (Url.origin_form url);
           Buffer.add_string buf " HTTP/1.1\r\n";
           if not (has_header "host" headers) then
             add_header_line buf ("Host", Url.authority url);
           if not (has_header "connection" headers) then
             add_header_line buf ("Connection", "keep-alive");
           (match content_length body with
           | None -> ()
           | Some length ->
               if not (has_header "content-length" headers) then
                 add_header_line buf ("Content-Length", string_of_int length));
           List.iter (add_header_line buf) (List.rev headers);
           Buffer.add_string buf "\r\n";
           (match body with
           | Empty -> ()
           | Fixed chunks -> List.iter (fun chunk -> Buffer.add_bytes buf chunk) chunks);
           write_string flow (Buffer.contents buf);
           Ok ()
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | _ -> Error (flow_write_error ~method_ ~url)))

let to_string ~method_ ~url ~headers ~body =
  let buffer = Buffer.create 256 in
  match write buffer ~method_ ~url ~headers ~body with
  | Ok () -> Ok (Buffer.contents buffer)
  | Error _ as error -> error
