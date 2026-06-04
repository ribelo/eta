(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type scheme : immutable_data = Http | Https

type parse_error : immutable_data =
  | Empty
  | Missing_scheme
  | Unsupported_scheme of string
  | Missing_authority
  | Missing_host
  | Userinfo_not_supported
  | Invalid_port of string
  | Invalid_character of {
      component : string;
      index : int;
      char : char;
    }

type span : immutable_data = {
  off : int;
  len : int;
}

type host_kind : immutable_data = Reg_name | Ip_literal

type t : immutable_data = {
  raw : string;
  scheme : scheme;
  host : span;
  host_kind : host_kind;
  port : int option;
  path : span option;
  query : span option;
  fragment : span option;
}

let span ~off ~len = { off; len }
let slice raw span = String.sub raw span.off span.len

let lowercase_ascii_slice raw off len =
  let bytes = Bytes.create len in
  for index = 0 to len - 1 do
    Bytes.unsafe_set bytes index
      (Eta.String_helpers.lowercase_ascii_char (String.unsafe_get raw (off + index)))
  done;
  Bytes.unsafe_to_string bytes

let is_ctl_or_space c =
  let code = Char.code c in
  code <= 0x20 || code = 0x7f

let validate_component raw component start finish =
  let rec loop index =
    if index >= finish then Ok ()
    else
      let char = raw.[index] in
      if is_ctl_or_space char then
        Error (Invalid_character { component; index; char })
      else loop (index + 1)
  in
  loop start

let find_from raw start stop char =
  let rec loop index =
    if index >= stop then None
    else if Char.equal raw.[index] char then Some index
    else loop (index + 1)
  in
  loop start

let find_first_path_mark raw start =
  let len = String.length raw in
  let rec loop index =
    if index >= len then len
    else
      match raw.[index] with
      | '/' | '?' | '#' -> index
      | _ -> loop (index + 1)
  in
  loop start

let[@zero_alloc] rec equal_ascii_case_insensitive_slice_loop raw token len index =
  index = len
  ||
  let c = Char.lowercase_ascii raw.[index] in
  Char.equal c token.[index]
  && equal_ascii_case_insensitive_slice_loop raw token len (index + 1)

let[@zero_alloc] equal_ascii_case_insensitive_prefix raw token len =
  len = String.length token
  && equal_ascii_case_insensitive_slice_loop raw token len 0

let parse_scheme raw =
  match find_from raw 0 (String.length raw) ':' with
  | None -> Error Missing_scheme
  | Some 0 -> Error Missing_scheme
  | Some colon ->
      if equal_ascii_case_insensitive_prefix raw "http" colon then Ok (Http, colon)
      else if equal_ascii_case_insensitive_prefix raw "https" colon then
        Ok (Https, colon)
      else Error (Unsupported_scheme (lowercase_ascii_slice raw 0 colon))

let parse_port raw start finish =
  if start = finish then Error (Invalid_port "")
  else
    let rec loop index acc =
      if index >= finish then
        if acc >= 1 && acc <= 65535 then Ok acc
        else Error (Invalid_port (String.sub raw start (finish - start)))
      else
        match raw.[index] with
        | '0' .. '9' as c ->
            let next = (acc * 10) + Char.code c - Char.code '0' in
            if next > 65535 then
              Error (Invalid_port (String.sub raw start (finish - start)))
            else loop (index + 1) next
        | _ -> Error (Invalid_port (String.sub raw start (finish - start)))
    in
    loop start 0

let parse_authority raw start finish =
  if start >= finish then Error Missing_authority
  else
    match find_from raw start finish '@' with
    | Some _ -> Error Userinfo_not_supported
    | None -> (
        match raw.[start] with
        | '[' -> (
            match find_from raw (start + 1) finish ']' with
            | None -> Error Missing_host
            | Some close when close = start + 1 -> Error Missing_host
            | Some close ->
                let host = span ~off:(start + 1) ~len:(close - start - 1) in
                if close + 1 = finish then Ok (host, Ip_literal, None)
                else if Char.equal raw.[close + 1] ':' then
                  parse_port raw (close + 2) finish
                  |> Result.map (fun port -> (host, Ip_literal, Some port))
                else Error (Invalid_port (String.sub raw (close + 1) (finish - close - 1))))
        | _ ->
            let colon = find_from raw start finish ':' in
            let host_finish = Option.value ~default:finish colon in
            if host_finish = start then Error Missing_host
            else
              let host = span ~off:start ~len:(host_finish - start) in
              match colon with
              | None -> Ok (host, Reg_name, None)
              | Some colon ->
                  parse_port raw (colon + 1) finish
                  |> Result.map (fun port -> (host, Reg_name, Some port)))

let parse_path_query_fragment raw start =
  let len = String.length raw in
  let path_start = if start < len && Char.equal raw.[start] '/' then start else len in
  let fragment_mark = find_from raw start len '#' in
  let query_end = Option.value ~default:len fragment_mark in
  let query_mark = find_from raw start query_end '?' in
  let path_end =
    match (query_mark, fragment_mark) with
    | Some query, Some fragment -> min query fragment
    | Some query, None -> query
    | None, Some fragment -> fragment
    | None, None -> len
  in
  let path =
    if path_start = len || path_end <= path_start then None
    else Some (span ~off:path_start ~len:(path_end - path_start))
  in
  let query =
    match query_mark with
    | None -> None
    | Some query_start ->
        Some (span ~off:(query_start + 1) ~len:(query_end - query_start - 1))
  in
  let fragment =
    match fragment_mark with
    | None -> None
    | Some fragment_start ->
        Some
          (span ~off:(fragment_start + 1)
             ~len:(len - fragment_start - 1))
  in
  (path, query, fragment)

let parse raw =
  if String.equal raw "" then Error Empty
  else
    match parse_scheme raw with
    | Error _ as error -> error
    | Ok (scheme, colon) ->
        let len = String.length raw in
        let authority_start = colon + 1 in
        if authority_start + 1 >= len
           || not
                (Char.equal raw.[authority_start] '/'
                && Char.equal raw.[authority_start + 1] '/')
        then Error Missing_authority
        else
          let authority_start = authority_start + 2 in
          let authority_end = find_first_path_mark raw authority_start in
          (match parse_authority raw authority_start authority_end with
          | Error _ as error -> error
          | Ok (host, host_kind, port) -> (
              match validate_component raw "host" host.off (host.off + host.len) with
              | Error _ as error -> error
              | Ok () ->
                  let path, query, fragment =
                    parse_path_query_fragment raw authority_end
                  in
                  let validate_opt component = function
                    | None -> Ok ()
                    | Some span ->
                        validate_component raw component span.off
                          (span.off + span.len)
                  in
                  Result.bind (validate_opt "path" path) (fun () ->
                      Result.bind (validate_opt "query" query) (fun () ->
                          Result.map
                            (fun () ->
                              {
                                raw;
                                scheme;
                                host;
                                host_kind;
                                port;
                                path;
                                query;
                                fragment;
                              })
                            (validate_opt "fragment" fragment)))))

let pp_parse_error fmt = function
  | Empty -> Format.pp_print_string fmt "empty URL"
  | Missing_scheme -> Format.pp_print_string fmt "missing URL scheme"
  | Unsupported_scheme scheme ->
      Format.fprintf fmt "unsupported URL scheme %S" scheme
  | Missing_authority -> Format.pp_print_string fmt "missing URL authority"
  | Missing_host -> Format.pp_print_string fmt "missing URL host"
  | Userinfo_not_supported ->
      Format.pp_print_string fmt "userinfo is not supported"
  | Invalid_port port -> Format.fprintf fmt "invalid URL port %S" port
  | Invalid_character { component; index; char } ->
      Format.fprintf fmt "invalid character %C in URL %s at byte %d" char
        component index

let parse_error_to_string error = Format.asprintf "%a" pp_parse_error error

let of_string raw =
  match parse raw with
  | Ok t -> t
  | Error error -> invalid_arg ("Http.Url.of_string: " ^ parse_error_to_string error)

let to_string t = t.raw
let scheme t = t.scheme
let scheme_to_string = function Http -> "http" | Https -> "https"
let host t = lowercase_ascii_slice t.raw t.host.off t.host.len
let port t = t.port
let default_port = function Http -> 80 | Https -> 443
let effective_port t = Option.value ~default:(default_port t.scheme) t.port
let path t = match t.path with None -> "/" | Some span -> slice t.raw span
let query t = Option.map (slice t.raw) t.query
let fragment t = Option.map (slice t.raw) t.fragment

let authority t =
  let host = host t in
  let host =
    match t.host_kind with Reg_name -> host | Ip_literal -> "[" ^ host ^ "]"
  in
  match t.port with
  | None -> host
  | Some port -> host ^ ":" ^ string_of_int port

let origin_form t =
  match query t with
  | None -> path t
  | Some query -> path t ^ "?" ^ query

let[@zero_alloc] has_capacity dst pos len =
  pos >= 0 && len >= 0 && pos <= Bytes.length dst - len

let[@zero_alloc] blit_literal dst pos value =
  let len = String.length value in
  if has_capacity dst pos len then (
    Bytes.blit_string value 0 dst pos len;
    pos + len)
  else -1

let[@zero_alloc] blit_span dst pos raw span =
  if has_capacity dst pos span.len then (
    Bytes.blit_string raw span.off dst pos span.len;
    pos + span.len)
  else -1

let[@zero_alloc] lowercase_ascii c =
  match c with 'A' .. 'Z' -> Char.chr (Char.code c + 32) | _ -> c

let[@zero_alloc] blit_lowercase_span dst pos raw span =
  if has_capacity dst pos span.len then (
    for offset = 0 to span.len - 1 do
      Bytes.unsafe_set dst (pos + offset)
        (lowercase_ascii (String.unsafe_get raw (span.off + offset)))
    done;
    pos + span.len)
  else -1

let[@zero_alloc] decimal_digits value =
  let rec loop digits n =
    if n < 10 then digits else loop (digits + 1) (n / 10)
  in
  loop 1 value

let[@zero_alloc] blit_int dst pos value =
  if value < 0 then -1
  else
    let digits = decimal_digits value in
    if not (has_capacity dst pos digits) then -1
    else (
      let n = ref value in
      for index = digits - 1 downto 0 do
        let digit = !n mod 10 in
        Bytes.unsafe_set dst (pos + index) (Char.chr (Char.code '0' + digit));
        n := !n / 10
      done;
      pos + digits)

let[@zero_alloc] blit_authority_raw dst pos t =
  let pos =
    match t.host_kind with
    | Reg_name -> blit_lowercase_span dst pos t.raw t.host
    | Ip_literal ->
        let pos = blit_literal dst pos "[" in
        if pos < 0 then pos
        else
          let pos = blit_lowercase_span dst pos t.raw t.host in
          if pos < 0 then pos else blit_literal dst pos "]"
  in
  if pos < 0 then pos
  else
    match t.port with
    | None -> pos
    | Some port ->
        let pos = blit_literal dst pos ":" in
        if pos < 0 then pos else blit_int dst pos port

let blit_authority dst ~pos t = blit_authority_raw dst pos t

let[@zero_alloc] blit_origin_form_raw dst pos t =
  let pos =
    match t.path with
    | None -> blit_literal dst pos "/"
    | Some path -> blit_span dst pos t.raw path
  in
  if pos < 0 then pos
  else
    match t.query with
    | None -> pos
    | Some query ->
        let pos = blit_literal dst pos "?" in
        if pos < 0 then pos else blit_span dst pos t.raw query

let blit_origin_form dst ~pos t = blit_origin_form_raw dst pos t

let redacted t = Redaction.uri t.raw
