(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type framing =
  | No_body
  | Fixed of int
  | Chunked

type error =
  | Invalid_content_length of string
  | Duplicate_content_length of string list
  | Content_length_with_transfer_encoding
  | Transfer_encoding_requires_http_11
  | Unsupported_transfer_encoding of string list

let pp_error fmt = function
  | Invalid_content_length value ->
      Format.fprintf fmt "invalid Content-Length %S" value
  | Duplicate_content_length values ->
      Format.fprintf fmt "duplicate Content-Length values %S"
        (String.concat ", " values)
  | Content_length_with_transfer_encoding ->
      Format.pp_print_string fmt
        "Content-Length cannot be combined with Transfer-Encoding"
  | Transfer_encoding_requires_http_11 ->
      Format.pp_print_string fmt
        "Transfer-Encoding requires HTTP/1.1 request framing"
  | Unsupported_transfer_encoding tokens ->
      Format.fprintf fmt "unsupported Transfer-Encoding %S"
        (String.concat ", " tokens)

let error_to_string error = Format.asprintf "%a" pp_error error

let trim value = Eta.String_helpers.trim value

let digit = function
  | '0' .. '9' as c -> Char.code c - Char.code '0'
  | _ -> -1

let parse_content_length value =
  let trimmed = trim value in
  let len = String.length trimmed in
  if len = 0 then Error (Invalid_content_length value)
  else
    let rec loop index acc =
      if index = len then Ok acc
      else
        let digit = digit (String.unsafe_get trimmed index) in
        if digit < 0 then Error (Invalid_content_length value)
        else if
          acc > max_int / 10 || (acc = max_int / 10 && digit > max_int mod 10)
        then Error (Invalid_content_length value)
        else loop (index + 1) ((acc * 10) + digit)
    in
    loop 0 0

let content_length_values headers =
  Header.get_all "content-length" headers

let parse_content_lengths values =
  match values with
  | [] -> Ok None
  | [ value ] -> (
      match parse_content_length value with
      | Error _ as error -> error
      | Ok length -> Ok (Some length))
  | _ ->
      let rec validate_all = function
        | [] -> Error (Duplicate_content_length values)
        | value :: rest -> (
            match parse_content_length value with
            | Error _ as error -> error
            | Ok _ -> validate_all rest)
      in
      validate_all values

let transfer_encoding_tokens headers =
  Header.get_all "transfer-encoding" headers
  |> List.concat_map (String.split_on_char ',')
  |> List.map Eta.String_helpers.lowercase_ascii_trim

let parse_transfer_encoding = function
  | [] -> Ok false
  | [ "chunked" ] -> Ok true
  | tokens -> Error (Unsupported_transfer_encoding tokens)

let of_headers ~version headers =
  let transfer_encoding = transfer_encoding_tokens headers in
  match
    (parse_content_lengths (content_length_values headers), transfer_encoding)
  with
  | Error error, _ -> Error error
  | Ok _, _ :: _ when not (version = Version.H1_1) ->
      Error Transfer_encoding_requires_http_11
  | Ok (Some _), _ :: _ -> Error Content_length_with_transfer_encoding
  | Ok None, _ -> (
      match parse_transfer_encoding transfer_encoding with
      | Error error -> Error error
      | Ok true -> Ok Chunked
      | Ok false -> Ok No_body)
  | Ok (Some length), [] -> Ok (Fixed length)
