(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type pending_headers = {
  stream_id : int;
  end_stream : bool;
  block : Buffer.t;
}

type t = {
  decoder : Hpack.Decoder.t;
  encoder : Hpack.Encoder.t;
  output : Buffer.t;
  final_seen : (int, unit) Hashtbl.t;
  mutable pending : string;
  mutable pending_off : int;
  mutable headers : pending_headers option;
}

let frame_data = 0x0
let frame_headers = 0x1
let frame_rst_stream = 0x3
let frame_continuation = 0x9

let flag_end_stream = 0x1
let flag_end_headers = 0x4
let flag_padded = 0x8
let flag_priority = 0x20

let max_frame_payload = 16 * 1024

let create () =
  {
    decoder = Hpack.Decoder.create 4096;
    encoder = Hpack.Encoder.create 4096;
    output = Buffer.create 4096;
    final_seen = Hashtbl.create 16;
    pending = "";
    pending_off = 0;
    headers = None;
  }

let error message =
  Error
    (Error.Connection_protocol_violation
       { kind = "h2_informational_filter"; message })

let code s i = Char.code (String.unsafe_get s i)

let frame_length s off =
  (code s (off + 0) lsl 16) lor (code s (off + 1) lsl 8) lor code s (off + 2)

let frame_type s off = code s (off + 3)
let frame_flags s off = code s (off + 4)

let frame_stream_id s off =
  ((code s (off + 5) land 0x7f) lsl 24)
  lor (code s (off + 6) lsl 16)
  lor (code s (off + 7) lsl 8)
  lor code s (off + 8)

let append_pending t data ~off ~len =
  if len > 0 then (
    let remaining = String.length t.pending - t.pending_off in
    if remaining = 0 then (
      t.pending <- String.sub data off len;
      t.pending_off <- 0)
    else (
      let buf = Bytes.create (remaining + len) in
      Bytes.blit_string t.pending t.pending_off buf 0 remaining;
      Bytes.blit_string data off buf remaining len;
      t.pending <- Bytes.unsafe_to_string buf;
      t.pending_off <- 0))

let emit_frame t ~frame_type ~flags ~stream_id payload =
  Buffer.add_string t.output
    (Frame.header ~length:(String.length payload)
       ~frame_type:(Other frame_type) ~flags ~stream_id);
  Buffer.add_string t.output payload

let emit_header_block t ~stream_id ~end_stream block =
  let total = String.length block in
  let rec loop off first =
    let remaining = total - off in
    if remaining <= max_frame_payload then
      let flags =
        flag_end_headers
        lor (if first && end_stream then flag_end_stream else 0)
      in
      let frame_type = if first then frame_headers else frame_continuation in
      emit_frame t ~frame_type ~flags ~stream_id
        (String.sub block off remaining)
    else
      let flags = if first && end_stream then flag_end_stream else 0 in
      let frame_type = if first then frame_headers else frame_continuation in
      emit_frame t ~frame_type ~flags ~stream_id
        (String.sub block off max_frame_payload);
      loop (off + max_frame_payload) false
  in
  loop 0 true

let header_block_fragment flags payload =
  let len = String.length payload in
  let pos = ref 0 in
  let pad_len =
    if flags land flag_padded = 0 then 0
    else if len = 0 then -1
    else (
      pos := 1;
      code payload 0)
  in
  if pad_len < 0 then error "PADDED HEADERS frame is missing Pad Length"
  else (
    if flags land flag_priority <> 0 then pos := !pos + 5;
    if !pos > len || !pos + pad_len > len then
      error "HEADERS padding/priority fields exceed frame payload"
    else Ok (String.sub payload !pos (len - !pos - pad_len)))

let decode_headers t block =
  match
    Angstrom.parse_string ~consume:Angstrom.Consume.All
      (Hpack.Decoder.decode_headers t.decoder)
      block
  with
  | Ok (Ok headers) -> Ok headers
  | Ok (Error Hpack.Decoding_error) -> error "HPACK decoding error"
  | Error message -> error ("HPACK parser error: " ^ message)

let encode_headers t headers =
  let faraday = Faraday.create 0x1000 in
  List.iter (Hpack.Encoder.encode_header t.encoder faraday) headers;
  Faraday.serialize_to_string faraday

let status_code headers =
  let rec loop = function
    | [] -> None
    | ({ Hpack.name = ":status"; value; _ } : Hpack.header) :: _ ->
        int_of_string_opt value
    | _ :: rest -> loop rest
  in
  loop headers

let is_informational = function
  | Some status -> status >= 100 && status < 200 && status <> 101
  | None -> false

let complete_headers t { stream_id; end_stream; block } =
  let already_final = Hashtbl.mem t.final_seen stream_id in
  match decode_headers t (Buffer.contents block) with
  | Error _ as error -> error
  | Ok headers ->
      if (not already_final) && is_informational (status_code headers) then
        if end_stream then error "informational response carried END_STREAM"
        else Ok ()
      else (
        if not already_final then Hashtbl.replace t.final_seen stream_id ();
        emit_header_block t ~stream_id ~end_stream (encode_headers t headers);
        if end_stream then Hashtbl.remove t.final_seen stream_id;
        Ok ())

let handle_headers t ~flags ~stream_id payload =
  match t.headers with
  | Some _ -> error "HEADERS arrived while a header block is open"
  | None -> (
      match header_block_fragment flags payload with
      | Error _ as error -> error
      | Ok fragment ->
          let pending =
            {
              stream_id;
              end_stream = flags land flag_end_stream <> 0;
              block = Buffer.create (String.length fragment);
            }
          in
          Buffer.add_string pending.block fragment;
          if flags land flag_end_headers <> 0 then complete_headers t pending
          else (
            t.headers <- Some pending;
            Ok ()))

let handle_continuation t ~flags ~stream_id payload =
  match t.headers with
  | None -> error "CONTINUATION arrived without an open header block"
  | Some pending when pending.stream_id <> stream_id ->
      error "CONTINUATION stream does not match open header block"
  | Some pending ->
      Buffer.add_string pending.block payload;
      if flags land flag_end_headers = 0 then Ok ()
      else (
        t.headers <- None;
        complete_headers t pending)

let pass_frame t frame_type flags stream_id ~off ~total =
  if frame_type = frame_rst_stream then Hashtbl.remove t.final_seen stream_id;
  if frame_type = frame_data && flags land flag_end_stream <> 0 then
    Hashtbl.remove t.final_seen stream_id;
  Buffer.add_substring t.output t.pending off total;
  Ok ()

let handle_frame t ~off ~total =
  let length = frame_length t.pending off in
  let frame_type = frame_type t.pending off in
  let flags = frame_flags t.pending off in
  let stream_id = frame_stream_id t.pending off in
  match (t.headers, frame_type) with
  | Some _, frame when frame <> frame_continuation ->
      error "non-CONTINUATION frame arrived while a header block is open"
  | _, frame when frame = frame_headers && stream_id > 0 ->
      let payload = String.sub t.pending (off + 9) length in
      handle_headers t ~flags ~stream_id payload
  | _, frame when frame = frame_continuation -> (
      let payload = String.sub t.pending (off + 9) length in
      match handle_continuation t ~flags ~stream_id payload with
      | Error _ as error -> error
      | Ok () -> Ok ())
  | _ -> pass_frame t frame_type flags stream_id ~off ~total

let rec process t =
  let available = String.length t.pending - t.pending_off in
  if available < 9 then Ok ()
  else
    let length = frame_length t.pending t.pending_off in
    let total = 9 + length in
    if available < total then Ok ()
    else
      let frame_off = t.pending_off in
      t.pending_off <- t.pending_off + total;
      match handle_frame t ~off:frame_off ~total with
      | Error _ as error -> error
      | Ok () -> process t

let feed t data ~off ~len =
  append_pending t data ~off ~len;
  process t

let take t =
  let data = Buffer.contents t.output in
  Buffer.clear t.output;
  data

let buffered_bytes t =
  String.length t.pending - t.pending_off
  +
  match t.headers with
  | None -> 0
  | Some headers -> Buffer.length headers.block

let is_passthrough t =
  String.length t.pending - t.pending_off = 0
  && t.headers = None
  && Hashtbl.length t.final_seen > 0
