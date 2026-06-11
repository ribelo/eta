(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type authority = {
  value : string;
  scheme : Url.scheme;
  host : string;
  port : int;
}

let connection_scheme ~tls = if tls then Url.Https else Url.Http

let is_hexdig = function
  | '0' .. '9' | 'A' .. 'F' | 'a' .. 'f' -> true
  | _ -> false

let is_reg_name_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' | '!'
  | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | ';' | '=' ->
      true
  | _ -> false

let is_ip_literal_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | ':' | '.' | '-' | '_' | '~'
  | '!' | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | ';' | '=' ->
      true
  | _ -> false

let valid_port value start finish =
  start < finish
  &&
  let rec loop index acc =
    if index = finish then acc >= 1 && acc <= 65535
    else
      match String.unsafe_get value index with
      | '0' .. '9' as c ->
          let next = (acc * 10) + Char.code c - Char.code '0' in
          next <= 65535 && loop (index + 1) next
      | _ -> false
  in
  loop start 0

let valid_reg_name value start finish =
  start < finish
  &&
  let rec loop index =
    if index = finish then true
    else
      match String.unsafe_get value index with
      | '%' ->
          index + 2 < finish
          && is_hexdig (String.unsafe_get value (index + 1))
          && is_hexdig (String.unsafe_get value (index + 2))
          && loop (index + 3)
      | c -> is_reg_name_char c && loop (index + 1)
  in
  loop start

let valid_ip_literal value start finish =
  start < finish
  &&
  let rec loop index =
    if index = finish then true
    else
      is_ip_literal_char (String.unsafe_get value index) && loop (index + 1)
  in
  loop start

let rec find_char_string value index finish char =
  if index >= finish then None
  else if Char.equal (String.unsafe_get value index) char then Some index
  else find_char_string value (index + 1) finish char

let valid_authority value =
  let len = String.length value in
  if len = 0 then false
  else if Char.equal (String.unsafe_get value 0) '[' then
    match find_char_string value 1 len ']' with
    | None -> false
    | Some close ->
        valid_ip_literal value 1 close
        &&
        if close + 1 = len then true
        else
          close + 2 < len
          && Char.equal (String.unsafe_get value (close + 1)) ':'
          && valid_port value (close + 2) len
  else
    let host_finish =
      Option.value ~default:len (find_char_string value 0 len ':')
    in
    valid_reg_name value 0 host_finish
    &&
    if host_finish = len then true
    else valid_port value (host_finish + 1) len

let parse_authority ~scheme value =
  if not (valid_authority value) then None
  else
    let raw = Url.scheme_to_string scheme ^ "://" ^ value in
    match Url.parse raw with
    | Error _ -> None
    | Ok url ->
        Some
          {
            value = Url.authority url;
            scheme;
            host = Url.host url;
            port = Url.effective_port url;
          }

let target_has_fragment target = Option.is_some (String.index_opt target '#')

let normalize_h1_target ~connection_scheme ~method_ ~target =
  if String.equal method_ "CONNECT" then
    Error "CONNECT is not supported by this server"
  else if String.equal target "*" then
    if String.equal method_ "OPTIONS" then Ok (target, None)
    else Error "asterisk-form request target is only valid with OPTIONS"
  else if String.starts_with ~prefix:"/" target then
    if target_has_fragment target then
      Error "request target must not include fragment"
    else Ok (target, None)
  else
    match Url.parse target with
    | Error _ -> Error "invalid request target form"
    | Ok url ->
        if Option.is_some (Url.fragment url) then
          Error "request target must not include fragment"
        else if Url.scheme url <> connection_scheme then
          Error "absolute-form request target scheme does not match connection"
        else
          Ok
            ( Url.origin_form url,
              Some
                {
                  value = Url.authority url;
                  scheme = Url.scheme url;
                  host = Url.host url;
                  port = Url.effective_port url;
                } )

let validate_h1_authority ~connection_scheme ~version ~method_:_ ~target:_
    ~target_authority ~headers =
  match Header.get_all "host" headers with
  | [] when version = Version.H1_1 ->
      Error "HTTP/1.1 request is missing Host header"
  | [] -> Ok ()
  | [ host ] ->
      let scheme =
        match target_authority with
        | Some authority -> authority.scheme
        | None -> connection_scheme
      in
      (match parse_authority ~scheme host with
      | None -> Error "invalid Host header"
      | Some host_authority -> (
          match target_authority with
          | Some authority
            when (not (String.equal host_authority.host authority.host))
                 || host_authority.port <> authority.port ->
              Error
                "absolute-form request target authority conflicts with Host \
                 header"
          | None | Some _ -> Ok ()))
  | _ -> Error "multiple Host headers"

let scheme_of_h2_string = function
  | "http" -> Some Url.Http
  | "https" -> Some Url.Https
  | _ -> None

let validate_h2_path ~method_ ~target =
  if String.equal method_ "CONNECT" then
    Error "CONNECT is not supported by this server"
  else if String.equal target "*" then
    if String.equal method_ "OPTIONS" then Ok ()
    else Error "asterisk-form request target is only valid with OPTIONS"
  else if String.equal target "" then Error "missing HTTP/2 :path"
  else if not (String.starts_with ~prefix:"/" target) then
    Error "invalid HTTP/2 :path"
  else if target_has_fragment target then
    Error "request target must not include fragment"
  else Ok ()

let validate_h2_request ~connection_scheme ~method_ ~scheme ~target ~authority =
  match scheme_of_h2_string scheme with
  | None -> Error "invalid HTTP/2 :scheme"
  | Some scheme when scheme <> connection_scheme ->
      Error "HTTP/2 :scheme does not match connection"
  | Some scheme -> (
      match authority with
      | None -> Error "missing HTTP/2 :authority"
      | Some authority -> (
          match parse_authority ~scheme authority with
          | None -> Error "invalid HTTP/2 :authority"
          | Some _ -> validate_h2_path ~method_ ~target))

let header_block_bytes headers =
  List.fold_left
    (fun total (name, value) ->
      total + String.length name + String.length value + 4)
    0 headers

let validate_header_block ~max_bytes ~max_headers ~kind headers =
  match Header.validate headers with
  | Some _ -> Error ("invalid " ^ kind ^ " header")
  | None ->
      let count = List.length headers in
      if count > max_headers then
        Error
          (Printf.sprintf "%s header count exceeds %d" kind max_headers)
      else
        let bytes = header_block_bytes headers in
        if bytes > max_bytes then
          Error
            (Printf.sprintf "%s header section exceeds %d bytes" kind max_bytes)
        else Ok ()

let validate_response_headers ~(limits : Server_config.limits) headers =
  validate_header_block ~max_bytes:limits.max_response_header_bytes
    ~max_headers:limits.max_response_headers ~kind:"response" headers

let validate_response_trailers ~(limits : Server_config.limits) trailers =
  validate_header_block ~max_bytes:limits.max_trailer_bytes
    ~max_headers:limits.max_trailers ~kind:"response trailer" trailers
