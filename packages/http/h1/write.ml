(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type body = Empty | Fixed of bytes list

let buffer_too_small = -1
let invalid_method = -2
let invalid_header = -3

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
  Option.is_some (Http_core.Header.get name headers)

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
  else if not (Http_core.Header.valid headers) then invalid_header
  else
    let pos = blit_literal dst pos method_ in
    let pos = blit_literal dst pos " " in
    let pos = Http_core.Url.blit_origin_form_raw dst pos url in
    let pos = blit_literal dst pos " HTTP/1.1\r\n" in
    let pos =
      if has_header_raw "host" headers then pos
      else
        let pos = blit_literal dst pos "Host: " in
        let pos = Http_core.Url.blit_authority_raw dst pos url in
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
        (Http_error.Error.make ~method_ ~uri:(Http_core.Url.to_string url)
           (Header_invalid { reason = "invalid request method" }))
  | n when n = invalid_header ->
      Error
        (Http_error.Error.make ~method_ ~uri:(Http_core.Url.to_string url)
           (Header_invalid { reason = "invalid request header" }))
  | _ ->
      Error
        (Http_error.Error.make ~method_ ~uri:(Http_core.Url.to_string url)
           (Header_invalid { reason = "request buffer too small" }))

let validate_headers ~method_ ~url headers =
  match Http_core.Header.validate headers with
  | None -> Ok ()
  | Some kind ->
      Error
        (Http_error.Error.make ~method_
           ~uri:(Http_core.Url.to_string url)
           kind)

let flow_write_error ~method_ ~url =
  Http_error.Error.make ~protocol:H1 ~method_
    ~uri:(Http_core.Url.to_string url)
    (Connection_closed { during = Http_request })

let write buffer ~method_ ~url ~headers ~body =
  if not (validate_method method_) then
    Error
      (Http_error.Error.make ~method_ ~uri:(Http_core.Url.to_string url)
         (Header_invalid { reason = "invalid request method" }))
  else
    match validate_headers ~method_ ~url headers with
    | Error _ as error -> error
    | Ok () ->
        Buffer.add_string buffer method_;
        Buffer.add_char buffer ' ';
        Buffer.add_string buffer (Http_core.Url.origin_form url);
        Buffer.add_string buffer " HTTP/1.1\r\n";
        if not (has_header "host" headers) then
          add_header_line buffer ("Host", Http_core.Url.authority url);
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
        Ok ()

let write_to_flow flow ~method_ ~url ~headers ~body =
  if not (validate_method method_) then
    Error
      (Http_error.Error.make ~method_ ~uri:(Http_core.Url.to_string url)
         (Header_invalid { reason = "invalid request method" }))
  else
    match validate_headers ~method_ ~url headers with
    | Error _ as error -> error
    | Ok () ->
        let buf = Buffer.create 512 in
        (try
           Buffer.add_string buf method_;
           Buffer.add_char buf ' ';
           Buffer.add_string buf (Http_core.Url.origin_form url);
           Buffer.add_string buf " HTTP/1.1\r\n";
           if not (has_header "host" headers) then
             add_header_line buf ("Host", Http_core.Url.authority url);
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
         with _ -> Error (flow_write_error ~method_ ~url))

let to_string ~method_ ~url ~headers ~body =
  let buffer = Buffer.create 256 in
  match write buffer ~method_ ~url ~headers ~body with
  | Ok () -> Ok (Buffer.contents buffer)
  | Error _ as error -> error
