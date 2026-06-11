(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

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

let pp_error fmt = function
  | Invalid_content_length value ->
      Format.fprintf fmt "invalid Content-Length %S" value
  | Conflicting_content_length { first; second } ->
      Format.fprintf fmt "conflicting Content-Length values %S and %S" first
        second
  | Content_length_with_transfer_encoding ->
      Format.pp_print_string fmt
        "Content-Length cannot be combined with Transfer-Encoding"
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

let parse_content_lengths = function
  | [] -> Ok None
  | first :: rest -> (
      match parse_content_length first with
      | Error _ as error -> error
      | Ok first_length ->
          let rec loop = function
            | [] -> Ok (Some first_length)
            | value :: rest -> (
                match parse_content_length value with
                | Error _ as error -> error
                | Ok length ->
                    if length = first_length then loop rest
                    else
                      Error
                        (Conflicting_content_length { first; second = value }))
          in
          loop rest)

let transfer_encoding_tokens headers =
  Header.get_all "transfer-encoding" headers
  |> List.concat_map (String.split_on_char ',')
  |> List.filter_map (fun token ->
         let token = Eta.String_helpers.lowercase_ascii_trim token in
         if String.length token = 0 then None else Some token)

let parse_transfer_encoding = function
  | [] -> Ok false
  | [ "chunked" ] -> Ok true
  | tokens -> Error (Unsupported_transfer_encoding tokens)

let of_headers headers =
  let transfer_encoding = transfer_encoding_tokens headers in
  match
    (parse_content_lengths (content_length_values headers), transfer_encoding)
  with
  | Error error, _ -> Error error
  | Ok (Some _), _ :: _ -> Error Content_length_with_transfer_encoding
  | Ok None, _ -> (
      match parse_transfer_encoding transfer_encoding with
      | Error error -> Error error
      | Ok true -> Ok Chunked
      | Ok false -> Ok No_body)
  | Ok (Some length), [] -> Ok (Fixed length)
