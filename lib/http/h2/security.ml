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
    max_goaway_per_connection = 1;
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
  mutable rst_stream_seen : int;
  mutable ping_seen : int;
  mutable empty_data_seen : int;
  mutable window_update_seen : int;
  response_headers_seen_by_stream : (int, int) Hashtbl.t;
  mutable header_block_bytes : int;
  mutable header_block_frames : int;
  mutable payload_observer : payload_observer;
}

and payload_observer =
  | Skip_payload
  | Window_update_payload of {
      stream_id : int;
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
    rst_stream_seen = 0;
    ping_seen = 0;
    empty_data_seen = 0;
    window_update_seen = 0;
    response_headers_seen_by_stream = Hashtbl.create 32;
    header_block_bytes = 0;
    header_block_frames = 0;
    payload_observer = Skip_payload;
  }

let end_headers flags = flags land 0x4 <> 0

let reset_header_block t =
  t.header_block_bytes <- 0;
  t.header_block_frames <- 0

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

let observe_payload t bs ~off ~len =
  match t.payload_observer with
  | Skip_payload -> None
  | Window_update_payload state ->
      for index = 0 to len - 1 do
        Bytes.set state.payload (state.payload_len + index)
          (Bigstringaf.get bs (off + index))
      done;
      state.payload_len <- state.payload_len + len;
      if state.payload_len = Bytes.length state.payload then (
        t.payload_observer <- Skip_payload;
        validate_window_update_payload ~stream_id:state.stream_id state.payload)
      else None

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
  match frame_type with
  | 0x0 when length = 0 -> account_empty_data t
  | 0x4 -> account_settings t
  | 0x7 -> account_goaway t
  | 0x3 -> account_rst_stream t
  | 0x6 -> account_ping t
  | 0x8 -> (
      match account_window_update t with
      | Some error -> Some error
      | None when length <> 4 ->
          Some
            (connection_protocol_violation ~kind:"window_update_length"
               ~message:
                 (Printf.sprintf
                    "WINDOW_UPDATE stream_id=%d payload length=%d, expected 4"
                    stream_id length))
      | None ->
          t.payload_observer <-
            Window_update_payload
              { stream_id; payload = Bytes.create 4; payload_len = 0 };
          None)
  | 0x1 | 0x5 | 0x9 ->
      account_header_bytes t ~frame_type ~flags ~length ~stream_id
  | _ -> None

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
