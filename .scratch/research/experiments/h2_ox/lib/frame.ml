(** OxCaml-optimized HTTP/2 frame parser.
    Replaces the Angstrom-based parser in ocaml-h2 with direct buffer iteration. *)

type frame_type =
  | Data | Headers | Priority | Rst_stream | Settings
  | Push_promise | Ping | Goaway | Window_update | Continuation

type settings_payload = (int * int32) list  (* (id, value) *)

type priority_payload = {
  exclusive : bool;
  stream_dep : int32;
  weight : int;
}

type frame_header = {
  payload_length : int;
  frame_type : frame_type;
  flags : int;
  stream_id : int32;
}

type frame_payload =
  | Data_payload
  | Headers_payload of string  (* header block fragment *)
  | Priority_payload of priority_payload
  | Rst_stream_payload of Error_code.t
  | Settings_payload of settings_payload
  | Push_promise_payload of { promised_stream_id : int32; headers : string }
  | Ping_payload of int64
  | Goaway_payload of { last_stream_id : int32; error_code : Error_code.t; debug_data : string }
  | Window_update_payload of int32
  | Continuation_payload of string

type frame = {
  header : frame_header;
  payload : frame_payload;
}

type parse_error =
  | Incomplete
  | Frame_size_error
  | Unknown_frame_type of int
  | Protocol_error of string

(* ── Frame type from byte ──────────────────────────────────────────────── *)

let frame_type_of_byte = function
  | 0x0 -> Data | 0x1 -> Headers | 0x2 -> Priority
  | 0x3 -> Rst_stream | 0x4 -> Settings | 0x5 -> Push_promise
  | 0x6 -> Ping | 0x7 -> Goaway | 0x8 -> Window_update
  | 0x9 -> Continuation
  | n -> raise_notrace (Failure (Printf.sprintf "unknown frame type %d" n))

(* ── Parser ─────────────────────────────────────────────────────────────── *)

(** Parse a frame header from 9 bytes at [off].
    Returns [frame_header] and advances [off] by 9. *)
let parse_frame_header bytes off =
  if off + 9 > Bytes.length bytes then Error Incomplete
  else
    let b0 = Char.code (Bytes.get bytes off) in
    let b1 = Char.code (Bytes.get bytes (off + 1)) in
    let b2 = Char.code (Bytes.get bytes (off + 2)) in
    let payload_length = (b0 lsl 16) lor (b1 lsl 8) lor b2 in
    let frame_type_byte = Char.code (Bytes.get bytes (off + 3)) in
    let flags = Char.code (Bytes.get bytes (off + 4)) in
    let sid0 = Char.code (Bytes.get bytes (off + 5)) in
    let sid1 = Char.code (Bytes.get bytes (off + 6)) in
    let sid2 = Char.code (Bytes.get bytes (off + 7)) in
    let sid3 = Char.code (Bytes.get bytes (off + 8)) in
    let stream_id =
      Int32.(logor (logor (shift_left (of_int sid0) 24)
                          (shift_left (of_int sid1) 16))
                  (logor (shift_left (of_int sid2) 8)
                          (of_int sid3)))
    in
    if payload_length > 0x3FFF then Error (Frame_size_error)
    else
      Ok ({ payload_length; flags; stream_id;
            frame_type =
              (try frame_type_of_byte frame_type_byte
               with Failure _ -> raise_notrace
                   (Failure (Printf.sprintf "bad type %d" frame_type_byte)))
          }, off + 9)

(** Parse a 32-bit unsigned integer from 4 bytes at [off]. *)
let get_int32 bytes off =
  let b0 = Int32.of_int (Char.code (Bytes.get bytes off)) in
  let b1 = Int32.of_int (Char.code (Bytes.get bytes (off + 1))) in
  let b2 = Int32.of_int (Char.code (Bytes.get bytes (off + 2))) in
  let b3 = Int32.of_int (Char.code (Bytes.get bytes (off + 3))) in
  Int32.(logor (logor (shift_left b0 24) (shift_left b1 16))
               (logor (shift_left b2 8) b3))

(** Parse the payload for a given frame header. *)
let parse_frame_payload bytes off header =
  let len = header.payload_length in
  let end_off = off + len in
  if end_off > Bytes.length bytes then Error Incomplete
  else
    let read_string start n =
      Bytes.sub_string bytes start n
    in
    match header.frame_type with
    | Data -> Ok (Data_payload, end_off)
    | Headers -> Ok (Headers_payload (read_string off len), end_off)
    | Priority ->
        if len < 5 then Error (Protocol_error "PRIORITY frame too short")
        else
          let sid = get_int32 bytes off in
          let exclusive = Int32.(compare sid (shift_left 1l 31)) >= 0 in
          let stream_dep = Int32.logand sid 0x7fffffffl in
          let weight = Char.code (Bytes.get bytes (off + 4)) in
          Ok (Priority_payload { exclusive; stream_dep; weight }, end_off)
    | Rst_stream ->
        if len < 4 then Error (Protocol_error "RST_STREAM frame too short")
        else
          let code = get_int32 bytes off in
          Ok (Rst_stream_payload (Error_code.of_int32 code), end_off)
    | Settings ->
        if len mod 6 <> 0 then Error (Protocol_error "SETTINGS payload not multiple of 6")
        else
          let rec loop i acc =
            if i >= end_off then Ok (List.rev acc, end_off)
            else
              let id = Int32.to_int (get_int32 bytes i) in
              let value = get_int32 bytes (i + 2) in
              loop (i + 6) ((id, value) :: acc)
          in loop off []
          |> Result.map (fun (pairs, eoff) -> (Settings_payload pairs, eoff))
    | Push_promise ->
        if len < 4 then Error (Protocol_error "PUSH_PROMISE frame too short")
        else
          let promised_sid = Int32.logand (get_int32 bytes off) 0x7fffffffl in
          Ok (Push_promise_payload
                { promised_stream_id = promised_sid
                ; headers = read_string (off + 4) (len - 4)
                }, end_off)
    | Ping ->
        if len < 8 then Error (Protocol_error "PING frame too short")
        else
          let b0 = Int64.of_int (Char.code (Bytes.get bytes off)) in
          let b1 = Int64.of_int (Char.code (Bytes.get bytes (off + 1))) in
          let b2 = Int64.of_int (Char.code (Bytes.get bytes (off + 2))) in
          let b3 = Int64.of_int (Char.code (Bytes.get bytes (off + 3))) in
          let b4 = Int64.of_int (Char.code (Bytes.get bytes (off + 4))) in
          let b5 = Int64.of_int (Char.code (Bytes.get bytes (off + 5))) in
          let b6 = Int64.of_int (Char.code (Bytes.get bytes (off + 6))) in
          let b7 = Int64.of_int (Char.code (Bytes.get bytes (off + 7))) in
          let opaque = Int64.(logor
            (logor (logor (shift_left b0 56) (shift_left b1 48))
                   (logor (shift_left b2 40) (shift_left b3 32)))
            (logor (logor (shift_left b4 24) (shift_left b5 16))
                   (logor (shift_left b6 8) b7))) in
          Ok (Ping_payload opaque, end_off)
    | Goaway ->
        if len < 8 then Error (Protocol_error "GOAWAY frame too short")
        else
          let last_sid = Int32.logand (get_int32 bytes off) 0x7fffffffl in
          let code = get_int32 bytes (off + 4) in
          let debug = read_string (off + 8) (len - 8) in
          Ok (Goaway_payload
                { last_stream_id = last_sid
                ; error_code = Error_code.of_int32 code
                ; debug_data = debug }, end_off)
    | Window_update ->
        if len < 4 then Error (Protocol_error "WINDOW_UPDATE frame too short")
        else
          let increment = Int32.logand (get_int32 bytes off) 0x7fffffffl in
          Ok (Window_update_payload increment, end_off)
    | Continuation -> Ok (Continuation_payload (read_string off len), end_off)

(** Parse a complete frame. Returns the frame and the new offset. *)
let parse_frame bytes off =
  match parse_frame_header bytes off with
  | Error _ as e -> e
  | Ok (header, off') ->
      match parse_frame_payload bytes off' header with
      | Error _ as e -> e
      | Ok (payload, off'') ->
          Ok ({ header; payload }, off'')
