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
        invalid_arg "Eta_http_h2.Frame.frame_type_code: code outside uint8";
      code

let frame_type_of_code = function
  | 0x0 -> Data
  | 0x1 -> Headers
  | 0x2 -> Priority
  | 0x3 -> Rst_stream
  | 0x4 -> Settings
  | 0x5 -> Push_promise
  | 0x6 -> Ping
  | 0x7 -> Goaway
  | 0x8 -> Window_update
  | 0x9 -> Continuation
  | code -> Other code

module Flags = struct
  type t = int

  let empty = 0
  let end_stream = 0x1
  let ack = 0x1
  let end_headers = 0x4
  let padded = 0x8
  let priority = 0x20
  let has flags mask = flags land mask <> 0
  let ( + ) = ( lor )
end

type envelope = {
  length : int;
  frame_type : int;
  flags : int;
  stream_id : int;
}

let header_size = 9

let[@zero_alloc] byte n = Char.chr (n land 0xff)

let validate_range label ~max value =
  if value < 0 || value > max then
    invalid_arg
      (Printf.sprintf "Eta_http_h2.Frame.%s outside 0..%d" label max)

let validate_header_bounds label len off =
  if off < 0 || off > len - header_size then
    invalid_arg
      (Printf.sprintf "Eta_http_h2.Frame.%s: need %d bytes at offset %d" label
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

let parse_envelope buf ~off ~len =
  if len < header_size then None
  else
    let get index = Bigstringaf.get buf (off + index) in
    Some (parse_header_with ~label:"parse_envelope" ~len ~get ~off)

let validate_envelope env ~max_frame_size =
  if env.length > max_frame_size then Error Error_code.Frame_size_error
  else if env.stream_id < 0 then Error Error_code.Protocol_error
  else Ok ()

let serialize_envelope ~buf ~off ~length ~frame_type ~flags ~stream_id =
  validate_range "length" ~max:0xffffff length;
  validate_range "flags" ~max:0xff flags;
  validate_range "stream_id" ~max:0x7fffffff stream_id;
  let frame_type = frame_type_code frame_type in
  let set i c = Bytes.unsafe_set buf (off + i) c in
  set 0 (byte (length lsr 16));
  set 1 (byte (length lsr 8));
  set 2 (byte length);
  set 3 (byte frame_type);
  set 4 (byte flags);
  set 5 (byte (stream_id lsr 24));
  set 6 (byte (stream_id lsr 16));
  set 7 (byte (stream_id lsr 8));
  set 8 (byte stream_id)

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
  if n < 0 || n > 0xffff_ffff then
    invalid_arg "Eta_http_h2.Frame.uint32: value outside uint32";
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
  if len < 0 then invalid_arg "Eta_http_h2.Frame.payload: negative length";
  String.make len '\000'

let[@zero_alloc] decode32u buf off =
  (Char.code (Bigstringaf.get buf off) lsl 24)
  lor (Char.code (Bigstringaf.get buf (off + 1)) lsl 16)
  lor (Char.code (Bigstringaf.get buf (off + 2)) lsl 8)
  lor Char.code (Bigstringaf.get buf (off + 3))

let[@zero_alloc] decode24u buf off =
  (Char.code (Bigstringaf.get buf off) lsl 16)
  lor (Char.code (Bigstringaf.get buf (off + 1)) lsl 8)
  lor Char.code (Bigstringaf.get buf (off + 2))

let[@zero_alloc] decode16u buf off =
  (Char.code (Bigstringaf.get buf off) lsl 8) lor Char.code (Bigstringaf.get buf (off + 1))

let decode_error_code code =
  match Error_code.of_int code with
  | Some ec -> Ok ec
  | None -> Ok Error_code.Protocol_error

module Data = struct
  type t = {
    data : Bigstringaf.t;
    off : int;
    len : int;
    padded : int;
  }

  let decode buf ~off ~envelope =
    if envelope.stream_id = 0 then
      Error Error_code.Protocol_error
    else if Flags.has envelope.flags Flags.padded then
      let pad_len = Char.code (Bigstringaf.get buf off) in
      if 1 + pad_len > envelope.length then
        Error Error_code.Protocol_error
      else
        let payload_len = envelope.length - 1 - pad_len in
        Ok { data = buf; off = off + 1; len = payload_len; padded = pad_len }
    else
      Ok { data = buf; off; len = envelope.length; padded = 0 }
end

module Headers = struct
  type priority = {
    exclusive : bool;
    stream_dependency : int;
    weight : int;
  }

  type t = {
    priority : priority option;
    header_block_fragment : Bigstringaf.t;
    off : int;
    len : int;
    padded : int;
  }

  let default_priority = { exclusive = false; stream_dependency = 0; weight = 16 }

  let decode_priority buf off =
    let raw = decode32u buf off in
    let exclusive = raw land 0x80000000 <> 0 in
    let stream_dependency = raw land 0x7fffffff in
    let weight = Char.code (Bigstringaf.get buf (off + 4)) + 1 in
    { exclusive; stream_dependency; weight }

  let decode buf ~off ~envelope =
    if envelope.stream_id = 0 then
      Error Error_code.Protocol_error
    else
      let pos = ref off in
      let pad_len =
        if Flags.has envelope.flags Flags.padded then (
          let n = Char.code (Bigstringaf.get buf !pos) in
          incr pos;
          n)
        else 0
      in
      let priority_len =
        if Flags.has envelope.flags Flags.priority then 5 else 0
      in
      let header_len = envelope.length - (!pos - off) - pad_len in
      if header_len < 0 then Error Error_code.Protocol_error
      else
        let priority =
          if Flags.has envelope.flags Flags.priority then
            Some (decode_priority buf !pos)
          else None
        in
        let fragment_off = !pos + priority_len in
        Ok
          {
            priority;
            header_block_fragment = buf;
            off = fragment_off;
            len = header_len;
            padded = pad_len;
          }
end

module Priority = struct
  type t = Headers.priority

  let decode buf ~off ~envelope =
    if envelope.stream_id = 0 then
      Error Error_code.Protocol_error
    else if envelope.length <> 5 then
      Error Error_code.Frame_size_error
    else
      Ok (Headers.decode_priority buf off)
end

module Rst_stream = struct
  type t = { error_code : Error_code.t }

  let decode buf ~off ~envelope =
    if envelope.stream_id = 0 then
      Error Error_code.Protocol_error
    else if envelope.length <> 4 then
      Error Error_code.Frame_size_error
    else
      match decode_error_code (decode32u buf off) with
      | Ok error_code -> Ok { error_code }
      | Error _ as e -> e
end

module Settings = struct
  type setting =
    | Header_table_size of int
    | Enable_push of bool
    | Max_concurrent_streams of int
    | Initial_window_size of int
    | Max_frame_size of int
    | Max_header_list_size of int

  type t = setting list

  let decode buf ~off ~envelope =
    if envelope.stream_id <> 0 then
      Error Error_code.Protocol_error
    else if envelope.length mod 6 <> 0 then
      Error Error_code.Frame_size_error
    else
      let rec loop acc pos =
        if pos >= off + envelope.length then Ok (List.rev acc)
        else
          let id = decode16u buf pos in
          let value = decode32u buf (pos + 2) in
          let setting =
            match id with
            | 1 -> Header_table_size value
            | 2 -> Enable_push (value <> 0)
            | 3 -> Max_concurrent_streams value
            | 4 -> Initial_window_size value
            | 5 -> Max_frame_size value
            | 6 -> Max_header_list_size value
            | _ -> Header_table_size value
          in
          loop (setting :: acc) (pos + 6)
      in
      loop [] off
end

module Ping = struct
  type t = { payload : bytes }

  let decode _buf ~off ~envelope =
    if envelope.stream_id <> 0 then
      Error Error_code.Protocol_error
    else if envelope.length <> 8 then
      Error Error_code.Frame_size_error
    else
      let payload = Bytes.create 8 in
      Bigstringaf.blit_to_bytes _buf ~src_off:off payload ~dst_off:0 ~len:8;
      Ok { payload }
end

module Goaway = struct
  type t = {
    last_stream_id : int;
    error_code : Error_code.t;
    debug_data : Bigstringaf.t;
    off : int;
    len : int;
  }

  let decode buf ~off ~envelope =
    if envelope.stream_id <> 0 then
      Error Error_code.Protocol_error
    else if envelope.length < 8 then
      Error Error_code.Frame_size_error
    else
      let last_stream_id = decode32u buf off land 0x7fffffff in
      match decode_error_code (decode32u buf (off + 4)) with
      | Ok error_code ->
          let debug_len = envelope.length - 8 in
          Ok
            {
              last_stream_id;
              error_code;
              debug_data = buf;
              off = off + 8;
              len = debug_len;
            }
      | Error _ as e -> e
end

module Window_update = struct
  type t = { window_size_increment : int }

  let decode buf ~off ~envelope =
    if envelope.length <> 4 then
      Error (Error_code.Frame_size_error, false)
    else
      let inc = decode32u buf off land 0x7fffffff in
      if inc = 0 then
        Error (Error_code.Protocol_error, envelope.stream_id <> 0)
      else
        Ok { window_size_increment = inc }
end

module Push_promise = struct
  type t = {
    promised_stream_id : int;
    header_block_fragment : Bigstringaf.t;
    off : int;
    len : int;
    padded : int;
  }

  let decode buf ~off ~envelope =
    if envelope.stream_id = 0 then
      Error Error_code.Protocol_error
    else
      let pos = ref off in
      let pad_len =
        if Flags.has envelope.flags Flags.padded then (
          let n = Char.code (Bigstringaf.get buf !pos) in
          incr pos;
          n)
        else 0
      in
      let promised_stream_id = decode32u buf !pos land 0x7fffffff in
      pos := !pos + 4;
      let header_len = envelope.length - (!pos - off) - pad_len in
      if header_len < 0 then Error Error_code.Protocol_error
      else
        Ok
          {
            promised_stream_id;
            header_block_fragment = buf;
            off = !pos;
            len = header_len;
            padded = pad_len;
          }
end

module Continuation = struct
  type t = {
    header_block_fragment : Bigstringaf.t;
    off : int;
    len : int;
  }

  let decode buf ~off ~envelope =
    if envelope.stream_id = 0 then
      Error Error_code.Protocol_error
    else
      Ok { header_block_fragment = buf; off; len = envelope.length }
end
