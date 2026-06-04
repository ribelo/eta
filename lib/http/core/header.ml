(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type t = (string * string) list
type name = string
type value = string

let empty = []
let header_invalid reason = Error.Header_invalid { reason }

let[@zero_alloc] is_tchar = function
  | '!' | '#' | '$' | '%' | '&' | '\'' | '*' | '+' | '-' | '.' | '^' | '_'
  | '`' | '|' | '~'
  | '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z' ->
      true
  | _ -> false

let[@zero_alloc] rec valid_name_loop name len index =
  index = len
  || (is_tchar (String.unsafe_get name index)
      && valid_name_loop name len (index + 1))

let[@zero_alloc] valid_name name =
  let len = String.length name in
  len > 0 && valid_name_loop name len 0

let[@zero_alloc] invalid_value_char c =
  let code = Char.code c in
  (code < 32 && code <> 9) || code = 127

let[@zero_alloc] rec valid_value_loop value len index =
  index = len
  || ((not (invalid_value_char (String.unsafe_get value index)))
      && valid_value_loop value len (index + 1))

let[@zero_alloc] valid_value value =
  valid_value_loop value (String.length value) 0

let[@zero_alloc] valid_header (name, value) = valid_name name && valid_value value

let[@zero_alloc] rec valid = function
  | [] -> true
  | header :: rest -> valid_header header && valid rest

let validate_name name =
  if valid_name name then None
  else if String.equal name "" then Some (header_invalid "empty header name")
  else Some (header_invalid "invalid header name")

let validate_value value =
  if valid_value value then None
  else Some (header_invalid "invalid header value")

let validate_header (name, value) =
  match validate_name name with
  | Some error -> Some error
  | None -> validate_value value

let rec validate = function
  | [] -> None
  | header :: rest -> (
      match validate_header header with
      | Some error -> Some error
      | None -> validate rest)

let name value =
  match validate_name value with
  | None -> Ok value
  | Some error -> Error error

let value value =
  match validate_value value with
  | None -> Ok value
  | Some error -> Error error

let pair name value =
  match validate_header (name, value) with
  | None -> Ok (name, value)
  | Some error -> Error error

let add name value headers =
  match pair name value with
  | Ok header -> Ok (header :: headers)
  | Error error -> Error error

let of_list headers =
  match validate headers with
  | None -> Ok headers
  | Some error -> Error error

let unsafe_add name value headers = (name, value) :: headers
let unsafe_of_list headers = headers
let to_list headers = headers
let normalize_name = Eta.String_helpers.lowercase_ascii_trim

let equal_normalized_name = Eta.String_helpers.trim_equal_ascii_ci

let get_all name headers =
  let normalized = normalize_name name in
  let rec loop acc = function
    | [] -> List.rev acc
    | (candidate, value) :: rest ->
        if equal_normalized_name normalized candidate then loop (value :: acc) rest
        else loop acc rest
  in
  loop [] headers

let get name headers =
  let normalized = normalize_name name in
  let rec loop = function
    | [] -> None
    | (candidate, value) :: rest ->
        if equal_normalized_name normalized candidate then Some value else loop rest
  in
  loop headers

let remove name headers =
  let normalized = normalize_name name in
  let rec loop acc = function
    | [] -> List.rev acc
    | (candidate, _) as header :: rest ->
        if equal_normalized_name normalized candidate then loop acc rest
        else loop (header :: acc) rest
  in
  loop [] headers
