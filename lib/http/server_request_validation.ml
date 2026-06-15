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

let is_ipvfuture_tail_char = function
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

let valid_ipvfuture value start finish =
  let rec version_loop index =
    if index >= finish then false
    else
      match String.unsafe_get value index with
      | '.' when index = start + 1 -> false
      | '.' -> tail_loop (index + 1)
      | char -> is_hexdig char && version_loop (index + 1)
  and tail_loop index =
    index < finish
    &&
    let rec tail_chars_loop index =
      index = finish
      ||
      (is_ipvfuture_tail_char (String.unsafe_get value index)
      && tail_chars_loop (index + 1))
    in
    tail_chars_loop index
  in
  start + 2 < finish
  && (match String.unsafe_get value start with 'v' | 'V' -> true | _ -> false)
  && version_loop (start + 1)

let valid_ip_literal value start finish =
  start < finish
  &&
  match String.unsafe_get value start with
  | 'v' | 'V' -> valid_ipvfuture value start finish
  | _ -> (
      match Ipaddr.V6.of_string (String.sub value start (finish - start)) with
      | Ok _ -> true
      | Error _ -> false)

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

let valid_connect_authority value =
  let len = String.length value in
  valid_authority value
  &&
  if len > 0 && Char.equal (String.unsafe_get value 0) '[' then
    match find_char_string value 1 len ']' with
    | None -> false
    | Some close ->
        close + 2 < len
        && Char.equal (String.unsafe_get value (close + 1)) ':'
        && valid_port value (close + 2) len
  else
    match find_char_string value 0 len ':' with
    | None -> false
    | Some colon -> valid_port value (colon + 1) len

let parse_port value start finish =
  let rec loop index acc =
    if index = finish then acc
    else
      loop (index + 1)
        ((acc * 10) + Char.code (String.unsafe_get value index) - Char.code '0')
  in
  loop start 0

let lowercase_ascii_slice value start finish =
  let len = finish - start in
  let bytes = Bytes.create len in
  for index = 0 to len - 1 do
    let c = String.unsafe_get value (start + index) in
    let c =
      match c with
      | 'A' .. 'Z' -> Char.unsafe_chr (Char.code c + 32)
      | _ -> c
    in
    Bytes.unsafe_set bytes index c
  done;
  Bytes.unsafe_to_string bytes

let parse_authority ~scheme value =
  if not (valid_authority value) then None
  else
    let len = String.length value in
    let host_start, host_finish, port =
      if Char.equal (String.unsafe_get value 0) '[' then
        match find_char_string value 1 len ']' with
        | None -> assert false
        | Some close ->
            let port =
              if close + 1 = len then None
              else Some (parse_port value (close + 2) len)
            in
            (1, close, port)
      else
        let host_finish =
          Option.value ~default:len (find_char_string value 0 len ':')
        in
        let port =
          if host_finish = len then None
          else Some (parse_port value (host_finish + 1) len)
        in
        (0, host_finish, port)
    in
    let host = lowercase_ascii_slice value host_start host_finish in
    let normalized_value =
      if host_start = 1 then "[" ^ host ^ "]" else host
    in
    let normalized_value =
      match port with
      | None -> normalized_value
      | Some port -> normalized_value ^ ":" ^ string_of_int port
    in
    Some
      {
        value = normalized_value;
        scheme;
        host;
        port = Option.value ~default:(Url.default_port scheme) port;
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

let valid_method_token method_ =
  let len = String.length method_ in
  len > 0
  &&
  let rec loop index =
    index = len
    ||
    match String.unsafe_get method_ index with
    | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '!' | '#' | '$' | '%' | '&'
    | '\'' | '*' | '+' | '-' | '.' | '^' | '_' | '`' | '|' | '~' ->
        loop (index + 1)
    | _ -> false
  in
  loop 0

let valid_origin_form_char = function
  | 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '-' | '.' | '_' | '~' | '!'
  | '$' | '&' | '\'' | '(' | ')' | '*' | '+' | ',' | ';' | '=' | ':' | '@'
  | '/' ->
      true
  | _ -> false

let valid_query_char = function
  | '?' -> true
  | char -> valid_origin_form_char char

let valid_pct_encoded value index finish =
  index + 2 < finish
  && is_hexdig (String.unsafe_get value (index + 1))
  && is_hexdig (String.unsafe_get value (index + 2))

let valid_h2_origin_form target =
  let len = String.length target in
  len > 0
  && Char.equal (String.unsafe_get target 0) '/'
  &&
  let rec loop in_query index =
    if index = len then true
    else
      match String.unsafe_get target index with
      | '%' -> valid_pct_encoded target index len && loop in_query (index + 3)
      | '?' -> loop true (index + 1)
      | char ->
          (if in_query then valid_query_char char else valid_origin_form_char char)
          && loop in_query (index + 1)
  in
  loop false 1

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
  else if not (valid_h2_origin_form target) then Error "invalid HTTP/2 :path"
  else Ok ()

let validate_h2_request ~connection_scheme ~method_ ~scheme ~target ~authority =
  if not (valid_method_token method_) then Error "invalid HTTP/2 :method"
  else if String.equal method_ "CONNECT" then
    match authority with
    | None -> Error "missing HTTP/2 :authority"
    | Some authority ->
        if not (String.equal scheme "") then
          Error "HTTP/2 CONNECT must omit :scheme"
        else if not (String.equal target "") then
          Error "HTTP/2 CONNECT must omit :path"
        else if not (valid_connect_authority authority) then
          Error "invalid HTTP/2 :authority"
        else Ok ()
  else
    match scheme_of_h2_string scheme with
    | None -> Error "invalid HTTP/2 :scheme"
    | Some scheme when scheme <> connection_scheme ->
        Error "HTTP/2 :scheme does not match connection"
    | Some scheme -> (
        match authority with
        | None -> Error "missing HTTP/2 :authority"
        | Some authority ->
            if valid_authority authority then validate_h2_path ~method_ ~target
            else Error "invalid HTTP/2 :authority")

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

let has_uppercase value =
  String.exists
    (function
      | 'A' .. 'Z' -> true
      | _ -> false)
    value

let h2_pseudo_header = function
  | ":method" -> Some `Method
  | ":scheme" -> Some `Scheme
  | ":authority" -> Some `Authority
  | ":path" -> Some `Path
  | _ -> None

let is_h2_pseudo_header name =
  String.length name > 0 && Char.equal (String.unsafe_get name 0) ':'

let validate_h2_header_value kind value =
  match Header.validate_value value with
  | Some _ -> Error ("invalid " ^ kind ^ " value")
  | None -> Ok ()

let validate_h2_pseudo_header_value name kind value =
  match validate_h2_header_value name value with
  | Error _ as error -> error
  | Ok () -> (
      match kind with
      | `Method ->
          if valid_method_token value then Ok ()
          else Error "invalid HTTP/2 :method"
      | `Path ->
          if valid_h2_origin_form value || String.equal value "*" then Ok ()
          else Error "invalid HTTP/2 :path"
      | `Scheme | `Authority -> Ok ())

let h2_forbidden_connection_header = function
  | "connection" | "keep-alive" | "proxy-connection" | "transfer-encoding"
  | "upgrade" ->
      true
  | _ -> false

let validate_h2_request_connection_header name value =
  if h2_forbidden_connection_header name then
    Error ("HTTP/2 connection-specific header " ^ name ^ " is forbidden")
  else if
    String.equal name "te"
    && not (Eta.String_helpers.trim_equal_ascii_ci value "trailers")
  then Error "HTTP/2 TE header may only contain trailers"
  else Ok ()

let validate_h2_response_connection_header name =
  if h2_forbidden_connection_header name || String.equal name "te" then
    Error ("HTTP/2 response header " ^ name ^ " is forbidden")
  else Ok ()

let digit = function
  | '0' .. '9' as c -> Char.code c - Char.code '0'
  | _ -> -1

let parse_content_length value =
  let trimmed = Eta.String_helpers.trim value in
  let len = String.length trimmed in
  if len = 0 then Error ("invalid HTTP/2 content-length " ^ value)
  else
    let rec loop index acc =
      if index = len then Ok acc
      else
        let digit = digit (String.unsafe_get trimmed index) in
        if digit < 0 then Error ("invalid HTTP/2 content-length " ^ value)
        else if
          acc > max_int / 10 || (acc = max_int / 10 && digit > max_int mod 10)
        then Error ("invalid HTTP/2 content-length " ^ value)
        else loop (index + 1) ((acc * 10) + digit)
    in
    loop 0 0

let h2_request_content_length headers =
  let values =
    headers
    |> List.filter_map (fun (name, value) ->
           if Eta.String_helpers.trim_equal_ascii_ci "content-length" name then
             Some value
           else None)
  in
  match values with
  | [] -> Ok None
  | [ value ] -> Result.map Option.some (parse_content_length value)
  | _ -> Error "multiple HTTP/2 content-length headers"

let validate_h2_host_authority ~scheme authority host =
  match scheme_of_h2_string scheme with
  | None -> Error "invalid HTTP/2 :scheme"
  | Some scheme -> (
      match parse_authority ~scheme authority with
      | None -> Error "invalid HTTP/2 :authority"
      | Some authority -> (
          match parse_authority ~scheme host with
          | None -> Error "invalid HTTP/2 host header"
          | Some host ->
              if
                String.equal host.host authority.host
                && host.port = authority.port
              then Ok ()
              else Error "HTTP/2 host header conflicts with :authority"))

let validate_h2_request_header_values headers =
  let rec loop regular_seen method_value scheme authority path_seen host =
    function
    | [] ->
        (match method_value with
        | None -> Error "missing HTTP/2 :method pseudo-header"
        | Some "CONNECT" -> (
            match authority with
            | None -> Error "missing HTTP/2 :authority pseudo-header"
            | Some authority ->
                if Option.is_some scheme then
                  Error "HTTP/2 CONNECT must omit :scheme pseudo-header"
                else if path_seen then
                  Error "HTTP/2 CONNECT must omit :path pseudo-header"
                else if not (valid_connect_authority authority) then
                  Error "invalid HTTP/2 :authority"
                else (
                  match host with
                  | Some host when not (String.equal host authority) ->
                      Error "HTTP/2 host header conflicts with :authority"
                  | None | Some _ -> Ok ()))
        | Some _ -> (
          match (scheme, authority) with
          | None, _ -> Error "missing HTTP/2 :scheme pseudo-header"
          | Some _, None ->
              Error "missing HTTP/2 :authority pseudo-header"
          | Some scheme, Some authority ->
              if not path_seen then Error "missing HTTP/2 :path pseudo-header"
              else (
                match host with
                | None -> Ok ()
                | Some host -> validate_h2_host_authority ~scheme authority host)))
    | (name, value) :: rest -> (
        if is_h2_pseudo_header name then
          if regular_seen then
            Error "HTTP/2 pseudo-header appears after regular header"
          else
            match h2_pseudo_header name with
            | None -> Error "invalid HTTP/2 pseudo-header"
            | Some kind ->
                let duplicate =
                  match kind with
                  | `Method -> Option.is_some method_value
                  | `Scheme -> Option.is_some scheme
                  | `Authority -> Option.is_some authority
                  | `Path -> path_seen
                in
                if duplicate then
                  Error ("duplicate HTTP/2 " ^ name ^ " pseudo-header")
                else
                  match validate_h2_pseudo_header_value name kind value with
                  | Error _ as error -> error
                  | Ok () ->
                      let method_value =
                        match kind with
                        | `Method -> Some value
                        | _ -> method_value
                      in
                      let scheme =
                        match kind with `Scheme -> Some value | _ -> scheme
                      in
                      let authority =
                        match kind with
                        | `Authority -> Some value
                        | _ -> authority
                      in
                      let path_seen = path_seen || kind = `Path in
                      loop regular_seen method_value scheme authority path_seen
                        host rest
        else if String.equal name "" then
          Error "empty HTTP/2 request header name"
        else
          match Header.validate_header (name, value) with
          | Some _ -> Error "invalid request header"
          | None when has_uppercase name ->
              Error "uppercase HTTP/2 request header name"
          | None -> (
              match validate_h2_request_connection_header name value with
              | Error _ as error -> error
              | Ok () ->
                  if String.equal name "host" then
                    match host with
                    | Some _ -> Error "multiple HTTP/2 host headers"
                    | None ->
                        loop true method_value scheme authority path_seen
                          (Some value) rest
                  else
                    loop true method_value scheme authority path_seen host rest))
  in
  loop false None None None false None headers

let validate_h2_request_headers ~(limits : Server_config.limits) headers =
  match validate_h2_request_header_values headers with
  | Error _ as error -> error
  | Ok () -> (
      match h2_request_content_length headers with
      | Error _ as error -> error
      | Ok _ ->
          let count = List.length headers in
          if count > limits.max_request_headers then
            Error
              (Printf.sprintf "request header count exceeds %d"
                 limits.max_request_headers)
          else
            let bytes = header_block_bytes headers in
            if bytes > limits.max_request_header_bytes then
              Error
                (Printf.sprintf "request header section exceeds %d bytes"
                   limits.max_request_header_bytes)
            else Ok ())

let validate_h2_request_trailer_values trailers =
  let rec loop = function
    | [] -> Ok ()
    | (name, value) :: rest -> (
        if String.equal name "" then
          Error "empty HTTP/2 request trailer header name"
        else
          match Header.validate_header (name, value) with
          | Some _ -> Error "invalid request trailer header"
          | None when is_h2_pseudo_header name ->
              Error "HTTP/2 request trailer pseudo-header is forbidden"
          | None when has_uppercase name ->
              Error "uppercase HTTP/2 request trailer header name"
          | None ->
              let name = Header.normalize_name name in
              if Chunked.forbidden_trailer_name name then
                Error ("forbidden HTTP/2 request trailer " ^ name)
              else loop rest)
  in
  loop trailers

let validate_h2_request_trailers ~(limits : Server_config.limits) trailers =
  match validate_h2_request_trailer_values trailers with
  | Error _ as error -> error
  | Ok () ->
      let count = List.length trailers in
      if count > limits.max_trailers then
        Error
          (Printf.sprintf "request trailer count exceeds %d"
             limits.max_trailers)
      else
        let bytes = header_block_bytes trailers in
        if bytes > limits.max_trailer_bytes then
          Error
            (Printf.sprintf "request trailer section exceeds %d bytes"
               limits.max_trailer_bytes)
        else Ok ()

let validate_h2_response_header_values ?(trailers = false) ~kind headers =
  let rec loop = function
    | [] -> Ok ()
    | (name, value) :: rest -> (
        if String.equal name "" then
          Error ("empty HTTP/2 " ^ kind ^ " header name")
        else
          match Header.validate_header (name, value) with
          | Some _ -> Error ("invalid " ^ kind ^ " header")
          | None when is_h2_pseudo_header name ->
              Error ("HTTP/2 " ^ kind ^ " pseudo-header is not user controlled")
          | None when has_uppercase name ->
              Error ("uppercase HTTP/2 " ^ kind ^ " header name")
          | None -> (
              let name = Header.normalize_name name in
              if trailers && Chunked.forbidden_trailer_name name then
                Error ("forbidden HTTP/2 response trailer " ^ name)
              else (
                match validate_h2_response_connection_header name with
                | Error _ as error -> error
                | Ok () -> loop rest)))
  in
  loop headers

let validate_h2_response_header_block ?(trailers = false) ~max_bytes
    ~max_headers ~kind headers =
  let headers = Header.to_list headers in
  match validate_h2_response_header_values ~trailers ~kind headers with
  | Error _ as error -> error
  | Ok () ->
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

let validate_h2_response_headers ~(limits : Server_config.limits) headers =
  validate_h2_response_header_block
    ~max_bytes:limits.max_response_header_bytes
    ~max_headers:limits.max_response_headers ~kind:"response" headers

let validate_h2_response_trailers ~(limits : Server_config.limits) trailers =
  validate_h2_response_header_block ~trailers:true
    ~max_bytes:limits.max_trailer_bytes
    ~max_headers:limits.max_trailers ~kind:"response trailer" trailers
