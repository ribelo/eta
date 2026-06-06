(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type opcode = Continuation | Text | Binary | Close | Ping | Pong

type frame = {
  fin : bool;
  opcode : opcode;
  payload : bytes;
}

type parse_error =
  | Incomplete
  | Reserved_bits
  | Unsupported_opcode of int
  | Control_fragmented
  | Control_payload_too_large
  | Non_minimal_length
  | Mask_required
  | Mask_forbidden
  | Payload_too_large of int64

let parse_error_to_string = function
  | Incomplete -> "incomplete frame"
  | Reserved_bits -> "reserved bits are set"
  | Unsupported_opcode opcode -> Printf.sprintf "unsupported opcode %d" opcode
  | Control_fragmented -> "control frame is fragmented"
  | Control_payload_too_large -> "control frame payload exceeds 125 bytes"
  | Non_minimal_length -> "payload length is not minimally encoded"
  | Mask_required -> "masked frame required"
  | Mask_forbidden -> "masked frame forbidden"
  | Payload_too_large length ->
      Printf.sprintf "payload length %Ld exceeds OCaml string limit" length

let opcode_to_int = function
  | Continuation -> 0x0
  | Text -> 0x1
  | Binary -> 0x2
  | Close -> 0x8
  | Ping -> 0x9
  | Pong -> 0xA

let opcode_of_int = function
  | 0x0 -> Some Continuation
  | 0x1 -> Some Text
  | 0x2 -> Some Binary
  | 0x8 -> Some Close
  | 0x9 -> Some Ping
  | 0xA -> Some Pong
  | _ -> None

let is_control = function Close | Ping | Pong -> true | _ -> false

let validate_frame frame =
  if is_control frame.opcode && not frame.fin then invalid_arg "WebSocket control frame fragmented";
  if is_control frame.opcode && Bytes.length frame.payload > 125 then
    invalid_arg "WebSocket control frame payload exceeds 125 bytes"

let write_uint16 bytes off value =
  Bytes.set_int16_be bytes off value

let write_uint64 bytes off value =
  Bytes.set_int64_be bytes off value

let apply_mask mask payload =
  let out = Bytes.copy payload in
  for index = 0 to Bytes.length out - 1 do
    let byte = Char.code (Bytes.get out index) in
    let key = Char.code (Bytes.get mask (index mod 4)) in
    Bytes.set out index (Char.chr (byte lxor key))
  done;
  out

let encode ?mask frame =
  validate_frame frame;
  (match mask with
  | None -> ()
  | Some mask ->
      if Bytes.length mask <> 4 then invalid_arg "WebSocket mask must be four bytes");
  let payload_len = Bytes.length frame.payload in
  let extended_len =
    if payload_len <= 125 then 0 else if payload_len <= 0xffff then 2 else 8
  in
  let mask_len = match mask with None -> 0 | Some _ -> 4 in
  let header_len = 2 + extended_len + mask_len in
  let out = Bytes.create (header_len + payload_len) in
  let b0 = (if frame.fin then 0x80 else 0) lor opcode_to_int frame.opcode in
  Bytes.set out 0 (Char.chr b0);
  let mask_bit = match mask with None -> 0 | Some _ -> 0x80 in
  if payload_len <= 125 then Bytes.set out 1 (Char.chr (mask_bit lor payload_len))
  else if payload_len <= 0xffff then (
    Bytes.set out 1 (Char.chr (mask_bit lor 126));
    write_uint16 out 2 payload_len)
  else (
    Bytes.set out 1 (Char.chr (mask_bit lor 127));
    write_uint64 out 2 (Int64.of_int payload_len));
  let payload_off =
    match mask with
    | None -> header_len
    | Some mask ->
        Bytes.blit mask 0 out (2 + extended_len) 4;
        header_len
  in
  let payload = match mask with None -> frame.payload | Some mask -> apply_mask mask frame.payload in
  Bytes.blit payload 0 out payload_off payload_len;
  out

let read_uint16 bytes off =
  Bytes.get_uint16_be bytes off

let read_uint64 bytes off = Bytes.get_int64_be bytes off

let decode ?(masked = false) bytes =
  let len = Bytes.length bytes in
  if len < 2 then Error Incomplete
  else
    let b0 = Char.code (Bytes.get bytes 0) in
    let b1 = Char.code (Bytes.get bytes 1) in
    if b0 land 0x70 <> 0 then Error Reserved_bits
    else
      match opcode_of_int (b0 land 0x0f) with
      | None -> Error (Unsupported_opcode (b0 land 0x0f))
      | Some opcode ->
          let fin = b0 land 0x80 <> 0 in
          let is_masked = b1 land 0x80 <> 0 in
          if masked && not is_masked then Error Mask_required
          else if (not masked) && is_masked then Error Mask_forbidden
          else if is_control opcode && not fin then Error Control_fragmented
          else
            let len_code = b1 land 0x7f in
            let length_result, off =
              if len_code < 126 then (Ok (Int64.of_int len_code), 2)
              else if len_code = 126 then
                if len < 4 then (Error Incomplete, 2)
                else
                  let value = read_uint16 bytes 2 in
                  if value < 126 then (Error Non_minimal_length, 4)
                  else (Ok (Int64.of_int value), 4)
              else if len < 10 then (Error Incomplete, 2)
              else
                let value = read_uint64 bytes 2 in
                if Int64.compare value 65536L < 0 then (Error Non_minimal_length, 10)
                else if Int64.compare value 0L < 0 then (Error (Payload_too_large value), 10)
                else (Ok value, 10)
            in
            match length_result with
            | Error error -> Error error
            | Ok payload_len64 ->
                if is_control opcode && Int64.compare payload_len64 125L > 0 then
                  Error Control_payload_too_large
                else if Int64.compare payload_len64 (Int64.of_int Sys.max_string_length) > 0 then
                  Error (Payload_too_large payload_len64)
                else
                  let payload_len = Int64.to_int payload_len64 in
                  let mask_len = if is_masked then 4 else 0 in
                  let payload_off = off + mask_len in
                  let consumed = payload_off + payload_len in
                  if len < consumed then Error Incomplete
                  else
                    let payload = Bytes.sub bytes payload_off payload_len in
                    let payload =
                      if is_masked then apply_mask (Bytes.sub bytes off 4) payload
                      else payload
                    in
                    Ok ({ fin; opcode; payload }, consumed)

let accept_key key =
  let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" in
  key ^ guid
  |> Openssl.sha1
  |> Base64.encode_string

let random_key () =
  Openssl.random_bytes 16 |> Bytes.unsafe_to_string |> Base64.encode_string
