(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type frame_type : immutable_data =
  | Data
  | Headers
  | Priority
  | Rst_stream
  | Settings
  | Push_promise
  | Ping
  | Goaway
  | Window_update
  | Continuation
  | Other of int

type envelope : immutable_data = {
  length : int;
  frame_type : int;
  flags : int;
  stream_id : int;
}

let header_size = 9

let frame_type_code = function
  | Data -> 0x0
  | Headers -> 0x1
  | Priority -> 0x2
  | Rst_stream -> 0x3
  | Settings -> 0x4
  | Push_promise -> 0x5
  | Ping -> 0x6
  | Goaway -> 0x7
  | Window_update -> 0x8
  | Continuation -> 0x9
  | Other code ->
      if code < 0 || code > 0xff then
        invalid_arg "Eta_http.H2.Frame.frame_type_code: code outside uint8";
      code

let byte n = Char.chr (n land 0xff)

let validate_range label ~max value =
  if value < 0 || value > max then
    invalid_arg
      (Printf.sprintf "Eta_http.H2.Frame.%s outside 0..%d" label max)

let validate_header_bounds label len off =
  if off < 0 || off > len - header_size then
    invalid_arg
      (Printf.sprintf "Eta_http.H2.Frame.%s: need %d bytes at offset %d" label
         header_size off)

let parse_header_with ~label ~len ~get ~off =
  validate_header_bounds label len off;
  let byte index = Char.code (get (off + index)) in
  {
    length = (byte 0 lsl 16) lor (byte 1 lsl 8) lor byte 2;
    frame_type = byte 3;
    flags = byte 4;
    stream_id =
      ((byte 5 land 0x7f) lsl 24)
      lor (byte 6 lsl 16) lor (byte 7 lsl 8) lor byte 8;
  }

let parse_header_string data ~off =
  parse_header_with ~label:"parse_header_string" ~len:(String.length data)
    ~get:(String.unsafe_get data) ~off

let parse_header_bytes data ~off =
  parse_header_with ~label:"parse_header_bytes" ~len:(Bytes.length data)
    ~get:(Bytes.unsafe_get data) ~off

let parse_header_buffer data ~off =
  parse_header_with ~label:"parse_header_buffer" ~len:(Buffer.length data)
    ~get:(Buffer.nth data) ~off

let header ~length ~frame_type ~flags ~stream_id =
  validate_range "length" ~max:0xffffff length;
  validate_range "flags" ~max:0xff flags;
  validate_range "stream_id" ~max:0x7fffffff stream_id;
  let frame_type = frame_type_code frame_type in
  String.init header_size @@ function
  | 0 -> byte (length lsr 16)
  | 1 -> byte (length lsr 8)
  | 2 -> byte length
  | 3 -> byte frame_type
  | 4 -> byte flags
  | 5 -> byte (stream_id lsr 24)
  | 6 -> byte (stream_id lsr 16)
  | 7 -> byte (stream_id lsr 8)
  | 8 -> byte stream_id
  | _ -> assert false

let uint32 n =
  if n < 0 then invalid_arg "Eta_http.H2.Frame.uint32: negative value";
  String.init 4 @@ function
  | 0 -> byte (n lsr 24)
  | 1 -> byte (n lsr 16)
  | 2 -> byte (n lsr 8)
  | 3 -> byte n
  | _ -> assert false

let settings = header ~length:0 ~frame_type:Settings ~flags:0 ~stream_id:0

let goaway_no_error ~last_stream_id =
  validate_range "last_stream_id" ~max:0x7fffffff last_stream_id;
  header ~length:8 ~frame_type:Goaway ~flags:0 ~stream_id:0
  ^ uint32 last_stream_id
  ^ uint32 0

let payload len =
  if len < 0 then invalid_arg "Eta_http.H2.Frame.payload: negative length";
  String.make len '\000'
