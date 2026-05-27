(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type frame_type =
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

let header ~length ~frame_type ~flags ~stream_id =
  validate_range "length" ~max:0xffffff length;
  validate_range "flags" ~max:0xff flags;
  validate_range "stream_id" ~max:0x7fffffff stream_id;
  let frame_type = frame_type_code frame_type in
  String.init 9 @@ function
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
