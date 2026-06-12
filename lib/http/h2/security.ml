module Error = Error

type config = {
  max_settings_per_connection : int;
  max_goaway_per_connection : int;
  max_rst_stream_per_connection : int;
  max_ping_per_connection : int;
  max_empty_data_frames_per_connection : int;
  max_window_update_per_connection : int;
  max_hpack_block_bytes : int;
  max_continuation_accumulator_bytes : int;
  max_response_headers_per_connection : int;
  max_header_name_bytes : int;
  max_header_value_bytes : int;
}

let default_config =
  {
    max_settings_per_connection = 10;
    max_goaway_per_connection = 8;
    max_rst_stream_per_connection = 100;
    max_ping_per_connection = 100;
    max_empty_data_frames_per_connection = 100;
    max_window_update_per_connection = 10_000;
    max_hpack_block_bytes = 256 * 1024;
    max_continuation_accumulator_bytes = 64 * 1024;
    max_response_headers_per_connection = 32;
    max_header_name_bytes = 8 * 1024;
    max_header_value_bytes = 64 * 1024;
  }

type t = {
  config : config;
  header : Bytes.t;
  mutable header_len : int;
  mutable payload_remaining : int;
  mutable settings_seen : int;
  mutable goaway_seen : int;
  mutable last_goaway_stream_id : int option;
  mutable rst_stream_seen : int;
  mutable ping_seen : int;
  mutable empty_data_seen : int;
  mutable window_update_seen : int;
  response_headers_seen_by_stream : (int, int) Hashtbl.t;
  mutable header_block_bytes : int;
  mutable header_block_frames : int;
  mutable open_header_stream : int option;
  mutable payload_observer : payload_observer;
}

and payload_observer =
  | Skip_payload
  | Window_update_payload of {
      stream_id : int;
      payload : Bytes.t;
      mutable payload_len : int;
    }
  | Settings_payload of {
      payload : Bytes.t;
      mutable payload_len : int;
    }
  | Goaway_payload of {
      payload : Bytes.t;
      mutable payload_len : int;
    }

let create ?(config = default_config) () =
  {
    config;
    header = Bytes.create Frame.header_size;
    header_len = 0;
    payload_remaining = 0;
    settings_seen = 0;
    goaway_seen = 0;
    last_goaway_stream_id = None;
    rst_stream_seen = 0;
    ping_seen = 0;
    empty_data_seen = 0;
    window_update_seen = 0;
    response_headers_seen_by_stream = Hashtbl.create 32;
    header_block_bytes = 0;
    header_block_frames = 0;
    open_header_stream = None;
    payload_observer = Skip_payload;
  }

let end_headers flags = flags land 0x4 <> 0

let reset_header_block t =
  t.header_block_bytes <- 0;
  t.header_block_frames <- 0;
  t.open_header_stream <- None

let account_settings t =
  t.settings_seen <- t.settings_seen + 1;
  if t.settings_seen > t.config.max_settings_per_connection then
    Some
      (Error.Settings_churn_rate_exceeded
         {
           observed_rate_hz = t.settings_seen;
           limit_hz = t.config.max_settings_per_connection;
         })
  else None

let account_goaway t =
  t.goaway_seen <- t.goaway_seen + 1;
  if t.goaway_seen > t.config.max_goaway_per_connection then
    Some (Error.Connection_closed { during = Error.Http_response })
  else None

let account_rst_stream t =
  t.rst_stream_seen <- t.rst_stream_seen + 1;
  if t.rst_stream_seen > t.config.max_rst_stream_per_connection then
    Some
      (Error.Rst_rate_exceeded
         {
           observed_per_second = t.rst_stream_seen;
           limit_per_second = t.config.max_rst_stream_per_connection;
         })
  else None

let account_ping t =
  t.ping_seen <- t.ping_seen + 1;
  if t.ping_seen > t.config.max_ping_per_connection then
    Some
      (Error.Ping_rate_exceeded
         {
           observed_rate_hz = t.ping_seen;
           limit_hz = t.config.max_ping_per_connection;
         })
  else None

let account_empty_data t =
  t.empty_data_seen <- t.empty_data_seen + 1;
  if t.empty_data_seen > t.config.max_empty_data_frames_per_connection then
    Some
      (Error.Empty_data_frame_rate_exceeded
         {
           observed_rate_hz = t.empty_data_seen;
           limit_hz = t.config.max_empty_data_frames_per_connection;
         })
  else None

let account_window_update t =
  t.window_update_seen <- t.window_update_seen + 1;
  if t.window_update_seen > t.config.max_window_update_per_connection then
    Some
      (Error.Window_update_rate_exceeded
         {
           observed_rate_hz = t.window_update_seen;
           limit_hz = t.config.max_window_update_per_connection;
         })
  else None

let account_response_headers t stream_id =
  let seen =
    Option.value
      (Hashtbl.find_opt t.response_headers_seen_by_stream stream_id)
      ~default:0
    + 1
  in
  Hashtbl.replace t.response_headers_seen_by_stream stream_id seen;
  if seen > t.config.max_response_headers_per_connection then
    Some
      (Error.Response_header_change_rate_exceeded
         {
           observed_rate_hz = seen;
           limit_hz = t.config.max_response_headers_per_connection;
         })
  else None

let saturating_add left right =
  if left > max_int - right then max_int else left + right

let continuation_flood t =
  Some
    (Error.Continuation_flood
       {
         accumulated_bytes = t.header_block_bytes;
         limit_bytes = t.config.max_continuation_accumulator_bytes;
         frames = t.header_block_frames;
       })

let account_header_bytes t ~frame_type ~flags ~length ~stream_id =
  match frame_type with
  | 0x1 | 0x5 ->
      t.open_header_stream <-
        (if end_headers flags then None else Some stream_id);
      t.header_block_bytes <- length;
      t.header_block_frames <- 1;
      (match
         if frame_type = 0x1 then account_response_headers t stream_id else None
       with
      | Some error -> Some error
      | None when length > t.config.max_hpack_block_bytes ->
        Some
          (Error.Hpack_decode_overflow
             {
               decoded_bytes = length;
               limit_bytes = t.config.max_hpack_block_bytes;
             })
      | None
        when (not (end_headers flags))
             && length > t.config.max_continuation_accumulator_bytes ->
        continuation_flood t
      | None when end_headers flags -> (
        reset_header_block t;
        None)
      | None -> None)
  | 0x9 ->
      t.header_block_bytes <- saturating_add t.header_block_bytes length;
      t.header_block_frames <- t.header_block_frames + 1;
      if t.header_block_bytes > t.config.max_continuation_accumulator_bytes then
        continuation_flood t
      else if end_headers flags then (
        reset_header_block t;
        None)
      else None
  | _ -> None

let connection_protocol_violation ~kind ~message =
  Error.Connection_protocol_violation { kind; message }

let protocol_violationf ~kind format =
  Printf.ksprintf
    (fun message -> Some (connection_protocol_violation ~kind ~message))
    format

let byte_at bytes index = Char.code (Bytes.unsafe_get bytes index)

let window_update_increment payload =
  ((byte_at payload 0 land 0x7f) lsl 24)
  lor (byte_at payload 1 lsl 16)
  lor (byte_at payload 2 lsl 8)
  lor (byte_at payload 3)

let validate_window_update_payload ~stream_id payload =
  let increment = window_update_increment payload in
  if increment = 0 then
    Some
      (connection_protocol_violation ~kind:"window_update_increment_zero"
         ~message:
           (Printf.sprintf
              "WINDOW_UPDATE stream_id=%d has zero flow-control increment"
              stream_id))
  else None

let uint16_at payload off =
  (byte_at payload off lsl 8) lor (byte_at payload (off + 1))

let uint32_at payload off =
  (byte_at payload off lsl 24)
  lor (byte_at payload (off + 1) lsl 16)
  lor (byte_at payload (off + 2) lsl 8)
  lor (byte_at payload (off + 3))

let validate_settings_payload payload =
  let id = uint16_at payload 0 in
  let value = uint32_at payload 2 in
  match id with
  | 0x2 when value <> 0 && value <> 1 ->
      protocol_violationf ~kind:"settings_enable_push"
        "SETTINGS_ENABLE_PUSH value=%d, expected 0 or 1" value
  | 0x4 when value > 0x7fff_ffff ->
      protocol_violationf ~kind:"settings_initial_window_size"
        "SETTINGS_INITIAL_WINDOW_SIZE value=%d exceeds 2^31-1" value
  | 0x5 when value < 16_384 || value > 16_777_215 ->
      protocol_violationf ~kind:"settings_max_frame_size"
        "SETTINGS_MAX_FRAME_SIZE value=%d outside 16384..16777215" value
  | _ -> None

let goaway_last_stream_id payload = uint32_at payload 0 land 0x7fff_ffff

let validate_goaway_payload t payload =
  let last_stream_id = goaway_last_stream_id payload in
  match t.last_goaway_stream_id with
  | Some previous when last_stream_id > previous ->
      protocol_violationf ~kind:"goaway_last_stream_id_increase"
        "GOAWAY last_stream_id increased from %d to %d" previous last_stream_id
  | _ ->
      t.last_goaway_stream_id <- Some last_stream_id;
      None

let validate_settings_frame ~flags ~length ~stream_id =
  if stream_id <> 0 then
    protocol_violationf ~kind:"settings_stream_id"
      "SETTINGS frame has stream_id=%d, expected 0" stream_id
  else if flags land 0x1 <> 0 && length <> 0 then
    protocol_violationf ~kind:"settings_ack_length"
      "SETTINGS ACK payload length=%d, expected 0" length
  else if flags land 0x1 = 0 && length mod 6 <> 0 then
    protocol_violationf ~kind:"settings_length"
      "SETTINGS payload length=%d is not a multiple of 6" length
  else None

let validate_ping_frame ~length ~stream_id =
  if stream_id <> 0 || length <> 8 then
    protocol_violationf ~kind:"ping_envelope"
      "PING frame stream_id=%d payload length=%d, expected stream_id=0 and \
       length=8"
      stream_id length
  else None

let validate_rst_stream_frame ~length ~stream_id =
  if stream_id = 0 || length <> 4 then
    protocol_violationf ~kind:"rst_stream_envelope"
      "RST_STREAM frame stream_id=%d payload length=%d, expected nonzero \
       stream_id and length=4"
      stream_id length
  else None

let validate_goaway_frame ~length ~stream_id =
  if stream_id <> 0 || length < 8 then
    protocol_violationf ~kind:"goaway_envelope"
      "GOAWAY frame stream_id=%d payload length=%d, expected stream_id=0 and \
       length>=8"
      stream_id length
  else None

let validate_data_frame ~stream_id =
  if stream_id = 0 then
    protocol_violationf ~kind:"data_stream_id"
      "DATA frame has stream_id=0, expected nonzero stream_id"
  else None

let validate_headers_frame ~stream_id =
  if stream_id = 0 then
    protocol_violationf ~kind:"headers_stream_id"
      "HEADERS frame has stream_id=0, expected nonzero stream_id"
  else None

let validate_priority_frame ~length ~stream_id =
  if stream_id = 0 || length <> 5 then
    protocol_violationf ~kind:"priority_envelope"
      "PRIORITY frame stream_id=%d payload length=%d, expected nonzero \
       stream_id and length=5"
      stream_id length
  else None

let validate_push_promise_frame ~length ~stream_id =
  if stream_id = 0 || length < 4 then
    protocol_violationf ~kind:"push_promise_envelope"
      "PUSH_PROMISE frame stream_id=%d payload length=%d, expected nonzero \
       stream_id and length>=4"
      stream_id length
  else None

let validate_continuation_frame t ~stream_id =
  match t.open_header_stream with
  | None ->
      protocol_violationf ~kind:"continuation_without_headers"
        "CONTINUATION frame stream_id=%d has no open header block" stream_id
  | Some expected when stream_id <> expected ->
      protocol_violationf ~kind:"continuation_stream_mismatch"
        "CONTINUATION frame stream_id=%d, expected stream_id=%d" stream_id
        expected
  | Some _ -> None

let validate_header_block_order t ~frame_type ~stream_id =
  match t.open_header_stream with
  | Some expected when frame_type <> 0x9 ->
      protocol_violationf ~kind:"continuation_expected"
        "frame type=0x%02x stream_id=%d arrived while header block for \
         stream_id=%d is open"
        frame_type stream_id expected
  | _ -> None

let observe_payload_byte t byte =
  match t.payload_observer with
  | Skip_payload -> None
  | Window_update_payload state ->
      Bytes.set state.payload state.payload_len byte;
      state.payload_len <- state.payload_len + 1;
      if state.payload_len = Bytes.length state.payload then (
        t.payload_observer <- Skip_payload;
        validate_window_update_payload ~stream_id:state.stream_id state.payload)
      else None
  | Settings_payload state ->
      Bytes.set state.payload state.payload_len byte;
      state.payload_len <- state.payload_len + 1;
      if state.payload_len = Bytes.length state.payload then
        match validate_settings_payload state.payload with
        | Some error -> Some error
        | None ->
            state.payload_len <- 0;
            None
      else None
  | Goaway_payload state ->
      Bytes.set state.payload state.payload_len byte;
      state.payload_len <- state.payload_len + 1;
      if state.payload_len = Bytes.length state.payload then (
        t.payload_observer <- Skip_payload;
        validate_goaway_payload t state.payload)
      else None

let observe_payload t bs ~off ~len =
  match t.payload_observer with
  | Skip_payload -> None
  | Window_update_payload _ | Settings_payload _ | Goaway_payload _ ->
      let rec loop index =
        if index = len then None
        else
          match observe_payload_byte t (Bigstringaf.get bs (off + index)) with
          | Some error -> Some error
          | None -> loop (index + 1)
      in
      loop 0

let complete_stream t stream_id =
  Hashtbl.remove t.response_headers_seen_by_stream stream_id

let start_frame t =
  let open Frame in
  let { length; frame_type; flags; stream_id } =
    parse_header_bytes t.header ~off:0
  in
  t.header_len <- 0;
  t.payload_remaining <- length;
  t.payload_observer <- Skip_payload;
  match validate_header_block_order t ~frame_type ~stream_id with
  | Some error -> Some error
  | None -> (
      match frame_type with
      | 0x0 -> (
          match validate_data_frame ~stream_id with
          | Some error -> Some error
          | None when length = 0 -> account_empty_data t
          | None -> None)
      | 0x1 -> (
          match validate_headers_frame ~stream_id with
          | Some error -> Some error
          | None ->
              account_header_bytes t ~frame_type ~flags ~length ~stream_id)
      | 0x2 -> validate_priority_frame ~length ~stream_id
      | 0x3 -> (
          match validate_rst_stream_frame ~length ~stream_id with
          | Some error -> Some error
          | None -> account_rst_stream t)
      | 0x4 -> (
          match validate_settings_frame ~flags ~length ~stream_id with
          | Some error -> Some error
          | None -> (
              match account_settings t with
              | Some error -> Some error
              | None ->
                  if length > 0 && flags land 0x1 = 0 then
                    t.payload_observer <-
                      Settings_payload
                        { payload = Bytes.create 6; payload_len = 0 };
                  None))
      | 0x5 -> (
          match validate_push_promise_frame ~length ~stream_id with
          | Some error -> Some error
          | None ->
              account_header_bytes t ~frame_type ~flags ~length ~stream_id)
      | 0x6 -> (
          match validate_ping_frame ~length ~stream_id with
          | Some error -> Some error
          | None -> account_ping t)
      | 0x7 -> (
          match validate_goaway_frame ~length ~stream_id with
          | Some error -> Some error
          | None -> (
              match account_goaway t with
              | Some error -> Some error
              | None ->
                  t.payload_observer <-
                    Goaway_payload { payload = Bytes.create 4; payload_len = 0 };
                  None))
      | 0x8 -> (
          if length <> 4 then
            Some
              (connection_protocol_violation ~kind:"window_update_length"
                 ~message:
                   (Printf.sprintf
                      "WINDOW_UPDATE stream_id=%d payload length=%d, expected 4"
                      stream_id length))
          else
            match account_window_update t with
            | Some error -> Some error
            | None ->
                t.payload_observer <-
                  Window_update_payload
                    { stream_id; payload = Bytes.create 4; payload_len = 0 };
                None)
      | 0x9 -> (
          match validate_continuation_frame t ~stream_id with
          | Some error -> Some error
          | None ->
              account_header_bytes t ~frame_type ~flags ~length ~stream_id)
      | _ -> None)

let observe_byte t byte =
  if t.payload_remaining > 0 then (
    t.payload_remaining <- t.payload_remaining - 1;
    observe_payload_byte t byte)
  else (
    Bytes.set t.header t.header_len byte;
    t.header_len <- t.header_len + 1;
    if t.header_len = Frame.header_size then start_frame t else None)

let observe t bs ~off ~len =
  let stop = off + len in
  let rec loop i =
    if i >= stop then None
    else if t.payload_remaining > 0 then (
      let skipped = min t.payload_remaining (stop - i) in
      t.payload_remaining <- t.payload_remaining - skipped;
      match observe_payload t bs ~off:i ~len:skipped with
      | Some error -> Some error
      | None -> loop (i + skipped))
    else
      let needed = Frame.header_size - t.header_len in
      let take = min needed (stop - i) in
      for j = 0 to take - 1 do
        Bytes.set t.header (t.header_len + j) (Bigstringaf.get bs (i + j))
      done;
      t.header_len <- t.header_len + take;
      if t.header_len = Frame.header_size then
        match start_frame t with
        | Some error -> Some error
        | None -> loop (i + take)
      else loop (i + take)
  in
  loop off

let has_nul value =
  String.exists (Char.equal '\000') value

let has_uppercase value =
  String.exists
    (function
      | 'A' .. 'Z' -> true
      | _ -> false)
    value

let header_invalid reason = Error.Header_invalid { reason }

let validate_header t (name, value) =
  match Header.validate_header (name, value) with
  | Some error -> Some error
  | None when String.length name > t.config.max_header_name_bytes ->
    Some (header_invalid "header name exceeds 8192 bytes")
  | None when String.length value > t.config.max_header_value_bytes ->
    Some (header_invalid "header value exceeds 65536 bytes")
  | None when has_nul name || has_nul value ->
      Some (header_invalid "header contains NUL")
  | None when has_uppercase name ->
    Some (header_invalid "uppercase h2 header name")
  | None -> None

let rec validate_headers_with t = function
  | [] -> None
  | header :: rest -> (
      match validate_header t header with
      | Some error -> Some error
      | None -> validate_headers_with t rest)

let validate_headers headers = validate_headers_with (create ()) headers
