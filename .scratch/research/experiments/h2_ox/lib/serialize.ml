(** OxCaml H2 frame serializer — writes directly to a Bytes buffer. *)

open Frame

let max_frame_size = 16384

(** Write a 24-bit integer to [buf] at [!pos]. *)
let put_uint24 buf pos_ref n =
  Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr ((n lsr 16) land 0xff));
  incr pos_ref;
  Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr ((n lsr 8) land 0xff));
  incr pos_ref;
  Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (n land 0xff));
  incr pos_ref

(** Write a 32-bit integer (big-endian) to [buf] at [!pos]. *)
let put_int32 buf pos_ref n =
  Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (Int32.(to_int (shift_right_logical n 24)) land 0xff));
  incr pos_ref;
  Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (Int32.(to_int (shift_right_logical n 16)) land 0xff));
  incr pos_ref;
  Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (Int32.(to_int (shift_right_logical n 8)) land 0xff));
  incr pos_ref;
  Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (Int32.to_int n land 0xff));
  incr pos_ref

(** Write a frame header: 9 bytes. *)
let write_frame_header buf pos_ref ~payload_length ~frame_type ~flags ~stream_id =
  put_uint24 buf pos_ref payload_length;
  Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (match frame_type with
    | Data -> 0 | Headers -> 1 | Priority -> 2 | Rst_stream -> 3
    | Settings -> 4 | Push_promise -> 5 | Ping -> 6 | Goaway -> 7
    | Window_update -> 8 | Continuation -> 9));
  incr pos_ref;
  Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr flags);
  incr pos_ref;
  put_int32 buf pos_ref stream_id

(** Write a HEADERS frame with the given header block fragment and flags. *)
let write_headers_frame buf pos_ref ~stream_id ~flags header_block =
  let len = String.length header_block in
  write_frame_header buf pos_ref ~payload_length:len ~frame_type:Headers ~flags ~stream_id;
  for i = 0 to len - 1 do
    Bytes.unsafe_set buf !pos_ref (String.unsafe_get header_block i);
    incr pos_ref
  done

(** Write a DATA frame. *)
let write_data_frame buf pos_ref ~stream_id ~flags data =
  let len = String.length data in
  write_frame_header buf pos_ref ~payload_length:len ~frame_type:Data ~flags ~stream_id;
  for i = 0 to len - 1 do
    Bytes.unsafe_set buf !pos_ref (String.unsafe_get data i);
    incr pos_ref
  done

(** Write a SETTINGS frame. *)
let write_settings_frame buf pos_ref settings =
  let payload_len = List.length settings * 6 in
  write_frame_header buf pos_ref ~payload_length:payload_len ~frame_type:Settings ~flags:0 ~stream_id:0l;
  List.iter (fun (id, value) ->
      put_int32 buf pos_ref (Int32.of_int id);
      put_int32 buf pos_ref value)
    settings

(** Write a PING frame with the given opaque data and ACK flag. *)
let write_ping_frame buf pos_ref ~is_ack opaque =
  write_frame_header buf pos_ref ~payload_length:8 ~frame_type:Ping
    ~flags:(if is_ack then 1 else 0) ~stream_id:0l;
  for i = 7 downto 0 do
    Bytes.unsafe_set buf !pos_ref (Char.unsafe_chr (Int64.to_int (Int64.shift_right_logical opaque (i * 8)) land 0xff));
    incr pos_ref
  done

(** Write a RST_STREAM frame. *)
let write_rst_stream_frame buf pos_ref ~stream_id error_code =
  write_frame_header buf pos_ref ~payload_length:4 ~frame_type:Rst_stream ~flags:0 ~stream_id;
  put_int32 buf pos_ref (match error_code with
    | Error_code.NoError -> 0l | ProtocolError -> 1l | InternalError -> 2l
    | FlowControlError -> 3l | SettingsTimeout -> 4l | StreamClosed -> 5l
    | FrameSizeError -> 6l | RefusedStream -> 7l | Cancel -> 8l
    | CompressionError -> 9l | ConnectError -> 10l | EnhanceYourCalm -> 11l
    | InadequateSecurity -> 12l | Http11Required -> 13l)

(** Write a GOAWAY frame. *)
let write_goaway_frame buf pos_ref ~last_stream_id ~error_code ~debug_data =
  let debug_len = match debug_data with Some s -> String.length s | None -> 0 in
  let payload_len = 8 + debug_len in
  write_frame_header buf pos_ref ~payload_length:payload_len ~frame_type:Goaway ~flags:0 ~stream_id:0l;
  put_int32 buf pos_ref last_stream_id;
  put_int32 buf pos_ref (match error_code with
    | Error_code.NoError -> 0l | ProtocolError -> 1l | InternalError -> 2l
    | FlowControlError -> 3l | SettingsTimeout -> 4l | StreamClosed -> 5l
    | FrameSizeError -> 6l | RefusedStream -> 7l | Cancel -> 8l
    | CompressionError -> 9l | ConnectError -> 10l | EnhanceYourCalm -> 11l
    | InadequateSecurity -> 12l | Http11Required -> 13l);
  (match debug_data with Some s -> for i = 0 to String.length s - 1 do Bytes.unsafe_set buf !pos_ref (String.unsafe_get s i); incr pos_ref done | None -> ())
