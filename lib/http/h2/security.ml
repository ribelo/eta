module Error = Error

type rate_limit = {
  burst : int;
  window_ms : int;
  max_per_connection : int option;
}

type config = {
  settings_rate : rate_limit;
  max_goaway_per_connection : int;
  rst_stream_rate : rate_limit;
  ping_rate : rate_limit;
  empty_data_rate : rate_limit;
  window_update_rate : rate_limit;
  max_hpack_block_bytes : int;
  max_continuation_accumulator_bytes : int;
  max_response_headers_per_stream : int;
  max_header_name_bytes : int;
  max_header_value_bytes : int;
}

type observation =
  | Pass
  | Connection_error of { code : int; kind : Error.kind }
  | Stream_error of { stream_id : int; code : int; kind : Error.kind }
  | Policy_close of { code : int; kind : Error.kind }

let h2_no_error = 0
let h2_protocol_error = 1
let h2_flow_control_error = 3
let h2_frame_size_error = 6
let h2_compression_error = 9
let h2_enhance_your_calm = 11

let connection_error ?(code = h2_protocol_error) kind =
  Connection_error { code; kind }

let stream_error ?(code = h2_protocol_error) ~stream_id kind =
  Stream_error { stream_id; code; kind }

let policy_close ?(code = h2_enhance_your_calm) kind =
  Policy_close { code; kind }

let observation_of_kind = function
  | Error.Connection_protocol_violation
      {
        kind =
          ( "h2_frame_size" | "settings_ack_length" | "settings_length"
          | "ping_length" | "rst_stream_length" | "goaway_length"
          | "push_promise_length" | "window_update_length" );
        _;
      } as kind ->
      connection_error ~code:h2_frame_size_error kind
  | Error.Connection_protocol_violation
      { kind = "settings_initial_window_size"; _ } as kind ->
      connection_error ~code:h2_flow_control_error kind
  | Error.Hpack_decode_overflow _ as kind ->
      connection_error ~code:h2_compression_error kind
  | Error.Continuation_flood _ | Error.Rst_count_exceeded _
  | Error.Ping_count_exceeded _ | Error.Empty_data_frame_count_exceeded _
  | Error.Window_update_count_exceeded _ | Error.Settings_count_exceeded _
  | Error.Response_header_count_exceeded _ as kind ->
      policy_close kind
  | Error.Connection_closed _ as kind -> policy_close ~code:h2_no_error kind
  | kind -> connection_error kind

let observation_of_option = function
  | None -> Pass
  | Some kind -> observation_of_kind kind

let rate_limit ~burst ~window_ms ~max_per_connection =
  { burst; window_ms; max_per_connection }

let remember_stream_error current candidate =
  match current with
  | Pass -> candidate
  | Connection_error _ | Stream_error _ | Policy_close _ -> current

let default_config =
  {
    settings_rate =
      rate_limit ~burst:10 ~window_ms:1_000
        ~max_per_connection:(Some 1_000_000);
    max_goaway_per_connection = 8;
    rst_stream_rate =
      rate_limit ~burst:100 ~window_ms:1_000
        ~max_per_connection:(Some 1_000_000);
    ping_rate =
      rate_limit ~burst:100 ~window_ms:60_000
        ~max_per_connection:(Some 1_000_000);
    empty_data_rate =
      rate_limit ~burst:100 ~window_ms:1_000
        ~max_per_connection:(Some 10_000_000);
    window_update_rate =
      rate_limit ~burst:10_000 ~window_ms:1_000
        ~max_per_connection:(Some 1_000_000_000);
    max_hpack_block_bytes = 256 * 1024;
    max_continuation_accumulator_bytes = 64 * 1024;
    max_response_headers_per_stream = 32;
    max_header_name_bytes = 8 * 1024;
    max_header_value_bytes = 64 * 1024;
  }

type rate_window = {
  mutable total : int;
  mutable window_start_ms : int64;
  mutable window_count : int;
}

type t = {
  config : config;
  mutable now_ms : int64;
  header : Bytes.t;
  mutable header_len : int;
  mutable payload_remaining : int;
  settings_seen : rate_window;
  mutable goaway_seen : int;
  mutable last_goaway_stream_id : int option;
  rst_stream_seen : rate_window;
  ping_seen : rate_window;
  empty_data_seen : rate_window;
  window_update_seen : rate_window;
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

let create_rate_window () =
  { total = 0; window_start_ms = 0L; window_count = 0 }

let validate_rate_limit name limit =
  if limit.burst <= 0 then invalid_arg (name ^ ".burst must be > 0");
  if limit.window_ms <= 0 then invalid_arg (name ^ ".window_ms must be > 0");
  match limit.max_per_connection with
  | Some max when max <= 0 ->
      invalid_arg (name ^ ".max_per_connection must be > 0")
  | Some _ | None -> ()

let validate_config config =
  validate_rate_limit "settings_rate" config.settings_rate;
  validate_rate_limit "rst_stream_rate" config.rst_stream_rate;
  validate_rate_limit "ping_rate" config.ping_rate;
  validate_rate_limit "empty_data_rate" config.empty_data_rate;
  validate_rate_limit "window_update_rate" config.window_update_rate

let create ?(config = default_config) () =
  validate_config config;
  {
    config;
    now_ms = 0L;
    header = Bytes.create Frame.header_size;
    header_len = 0;
    payload_remaining = 0;
    settings_seen = create_rate_window ();
    goaway_seen = 0;
    last_goaway_stream_id = None;
    rst_stream_seen = create_rate_window ();
    ping_seen = create_rate_window ();
    empty_data_seen = create_rate_window ();
    window_update_seen = create_rate_window ();
    response_headers_seen_by_stream = Hashtbl.create 32;
    header_block_bytes = 0;
    header_block_frames = 0;
    open_header_stream = None;
    payload_observer = Skip_payload;
  }

let has_open_header_block t = Option.is_some t.open_header_stream

let end_headers flags = flags land 0x4 <> 0

let reset_header_block t =
  t.header_block_bytes <- 0;
  t.header_block_frames <- 0;
  t.open_header_stream <- None

let increment_saturating value =
  if value = max_int then max_int else value + 1

let reset_rate_window window now =
  window.window_start_ms <- now;
  window.window_count <- 1

let in_current_window ~now ~start ~window_ms =
  Int64.compare now start >= 0
  && Int64.compare (Int64.sub now start) (Int64.of_int window_ms) < 0

let account_rate window limit make_error now =
  window.total <- increment_saturating window.total;
  if window.window_count = 0
     || not
          (in_current_window ~now ~start:window.window_start_ms
             ~window_ms:limit.window_ms)
  then reset_rate_window window now
  else window.window_count <- increment_saturating window.window_count;
  match limit.max_per_connection with
  | Some max when window.total > max -> Some (make_error window.total max)
  | _ when window.window_count > limit.burst ->
      Some (make_error window.window_count limit.burst)
  | _ -> None

let settings_count_exceeded observed_count limit =
  Error.Settings_count_exceeded { observed_count; limit }

let rst_count_exceeded observed_count limit =
  Error.Rst_count_exceeded { observed_count; limit }

let ping_count_exceeded observed_count limit =
  Error.Ping_count_exceeded { observed_count; limit }

let empty_data_count_exceeded observed_count limit =
  Error.Empty_data_frame_count_exceeded { observed_count; limit }

let window_update_count_exceeded observed_count limit =
  Error.Window_update_count_exceeded { observed_count; limit }

let account_settings t =
  account_rate t.settings_seen t.config.settings_rate settings_count_exceeded
    t.now_ms

let account_goaway t =
  t.goaway_seen <- t.goaway_seen + 1;
  if t.goaway_seen > t.config.max_goaway_per_connection then
    Some (Error.Connection_closed { during = Error.Http_response })
  else None

let account_rst_stream t =
  account_rate t.rst_stream_seen t.config.rst_stream_rate rst_count_exceeded
    t.now_ms

let account_ping t =
  account_rate t.ping_seen t.config.ping_rate ping_count_exceeded t.now_ms

let account_empty_data t =
  account_rate t.empty_data_seen t.config.empty_data_rate
    empty_data_count_exceeded t.now_ms

let account_window_update t =
  account_rate t.window_update_seen t.config.window_update_rate
    window_update_count_exceeded t.now_ms

let account_response_headers t stream_id =
  let seen =
    Option.value
      (Hashtbl.find_opt t.response_headers_seen_by_stream stream_id)
      ~default:0
    + 1
  in
  Hashtbl.replace t.response_headers_seen_by_stream stream_id seen;
  if seen > t.config.max_response_headers_per_stream then
    Some
      (Error.Response_header_count_exceeded
         {
           observed_count = seen;
           limit = t.config.max_response_headers_per_stream;
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
    let kind =
      connection_protocol_violation ~kind:"window_update_increment_zero"
        ~message:
          (Printf.sprintf
             "WINDOW_UPDATE stream_id=%d has zero flow-control increment"
             stream_id)
    in
    if stream_id = 0 then connection_error kind
    else stream_error ~stream_id kind
  else Pass

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
  if length <> 8 then
    protocol_violationf ~kind:"ping_length"
      "PING frame payload length=%d, expected length=8" length
  else if stream_id <> 0 then
    protocol_violationf ~kind:"ping_stream_id"
      "PING frame stream_id=%d, expected stream_id=0" stream_id
  else None

let validate_rst_stream_frame ~length ~stream_id =
  if length <> 4 then
    protocol_violationf ~kind:"rst_stream_length"
      "RST_STREAM frame payload length=%d, expected length=4" length
  else if stream_id = 0 then
    protocol_violationf ~kind:"rst_stream_id"
      "RST_STREAM frame stream_id=0, expected nonzero stream_id"
  else None

let validate_goaway_frame ~length ~stream_id =
  if length < 8 then
    protocol_violationf ~kind:"goaway_length"
      "GOAWAY frame payload length=%d, expected length>=8" length
  else if stream_id <> 0 then
    protocol_violationf ~kind:"goaway_stream_id"
      "GOAWAY frame stream_id=%d, expected stream_id=0" stream_id
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
  if stream_id = 0 then
    protocol_violationf ~kind:"priority_stream_id"
      "PRIORITY frame stream_id=0, expected nonzero stream_id"
  else if length <> 5 then
    protocol_violationf ~kind:"priority_length"
      "PRIORITY frame payload length=%d, expected length=5" length
  else None

let validate_push_promise_frame ~length ~stream_id =
  if length < 4 then
    protocol_violationf ~kind:"push_promise_length"
      "PUSH_PROMISE frame payload length=%d, expected length>=4" length
  else if stream_id = 0 then
    protocol_violationf ~kind:"push_promise_stream_id"
      "PUSH_PROMISE frame stream_id=0, expected nonzero stream_id"
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
  | Skip_payload -> Pass
  | Window_update_payload state ->
      Bytes.set state.payload state.payload_len byte;
      state.payload_len <- state.payload_len + 1;
      if state.payload_len = Bytes.length state.payload then (
        t.payload_observer <- Skip_payload;
        validate_window_update_payload ~stream_id:state.stream_id state.payload)
      else Pass
  | Settings_payload state ->
      Bytes.set state.payload state.payload_len byte;
      state.payload_len <- state.payload_len + 1;
      if state.payload_len = Bytes.length state.payload then
        match validate_settings_payload state.payload with
        | Some error -> observation_of_kind error
        | None ->
            state.payload_len <- 0;
            Pass
      else Pass
  | Goaway_payload state ->
      Bytes.set state.payload state.payload_len byte;
      state.payload_len <- state.payload_len + 1;
      if state.payload_len = Bytes.length state.payload then (
        t.payload_observer <- Skip_payload;
        observation_of_option (validate_goaway_payload t state.payload))
      else Pass

let observe_payload t bs ~off ~len =
  match t.payload_observer with
  | Skip_payload -> Pass
  | Window_update_payload _ | Settings_payload _ | Goaway_payload _ ->
      let rec loop pending index =
        if index = len then pending
        else
          match observe_payload_byte t (Bigstringaf.get bs (off + index)) with
          | Pass -> loop pending (index + 1)
          | Stream_error _ as error ->
              loop (remember_stream_error pending error) (index + 1)
          | Connection_error _ | Policy_close _ as error -> error
      in
      loop Pass 0

let complete_stream t stream_id =
  Hashtbl.remove t.response_headers_seen_by_stream stream_id

let tracked_header_streams t =
  Hashtbl.length t.response_headers_seen_by_stream

let start_frame t =
  let open Frame in
  let { length; frame_type; flags; stream_id } =
    parse_header_bytes t.header ~off:0
  in
  t.header_len <- 0;
  t.payload_remaining <- length;
  t.payload_observer <- Skip_payload;
  match validate_header_block_order t ~frame_type ~stream_id with
  | Some error -> observation_of_kind error
  | None -> (
      match frame_type with
      | 0x0 -> (
          match validate_data_frame ~stream_id with
          | Some error -> observation_of_kind error
          | None when length = 0 -> observation_of_option (account_empty_data t)
          | None -> Pass)
      | 0x1 -> (
          match validate_headers_frame ~stream_id with
          | Some error -> observation_of_kind error
          | None ->
              observation_of_option
                (account_header_bytes t ~frame_type ~flags ~length ~stream_id))
      | 0x2 -> (
          match validate_priority_frame ~length ~stream_id with
          | None -> Pass
          | Some error when stream_id = 0 -> observation_of_kind error
          | Some error -> stream_error ~code:h2_frame_size_error ~stream_id error)
      | 0x3 -> (
          match validate_rst_stream_frame ~length ~stream_id with
          | Some error -> observation_of_kind error
          | None -> observation_of_option (account_rst_stream t))
      | 0x4 -> (
          match validate_settings_frame ~flags ~length ~stream_id with
          | Some error -> observation_of_kind error
          | None -> (
              match observation_of_option (account_settings t) with
              | Connection_error _ | Stream_error _ | Policy_close _ as error ->
                  error
              | Pass ->
                  if length > 0 && flags land 0x1 = 0 then
                    t.payload_observer <-
                      Settings_payload
                        { payload = Bytes.create 6; payload_len = 0 };
                  Pass))
      | 0x5 -> (
          match validate_push_promise_frame ~length ~stream_id with
          | Some error -> observation_of_kind error
          | None ->
              observation_of_option
                (account_header_bytes t ~frame_type ~flags ~length ~stream_id))
      | 0x6 -> (
          match validate_ping_frame ~length ~stream_id with
          | Some error -> observation_of_kind error
          | None -> observation_of_option (account_ping t))
      | 0x7 -> (
          match validate_goaway_frame ~length ~stream_id with
          | Some error -> observation_of_kind error
          | None -> (
              match observation_of_option (account_goaway t) with
              | Connection_error _ | Stream_error _ | Policy_close _ as error ->
                  error
              | Pass ->
                  t.payload_observer <-
                    Goaway_payload { payload = Bytes.create 4; payload_len = 0 };
                  Pass))
      | 0x8 -> (
          if length <> 4 then
            observation_of_kind
              (connection_protocol_violation ~kind:"window_update_length"
                 ~message:
                   (Printf.sprintf
                      "WINDOW_UPDATE stream_id=%d payload length=%d, expected 4"
                      stream_id length))
          else
            match observation_of_option (account_window_update t) with
            | Connection_error _ | Stream_error _ | Policy_close _ as error ->
                error
            | Pass ->
                t.payload_observer <-
                  Window_update_payload
                    { stream_id; payload = Bytes.create 4; payload_len = 0 };
                Pass)
      | 0x9 -> (
          match validate_continuation_frame t ~stream_id with
          | Some error -> observation_of_kind error
          | None ->
              observation_of_option
                (account_header_bytes t ~frame_type ~flags ~length ~stream_id))
      | _ -> Pass)

let observe_byte t byte =
  if t.payload_remaining > 0 then (
    t.payload_remaining <- t.payload_remaining - 1;
    observe_payload_byte t byte)
  else (
    Bytes.set t.header t.header_len byte;
    t.header_len <- t.header_len + 1;
    if t.header_len = Frame.header_size then start_frame t else Pass)

let observe_result t bs ~off ~len ~now_ms =
  t.now_ms <- now_ms;
  let stop = off + len in
  let rec loop pending i =
    if i >= stop then pending
    else if t.payload_remaining > 0 then (
      let skipped = min t.payload_remaining (stop - i) in
      t.payload_remaining <- t.payload_remaining - skipped;
      match observe_payload t bs ~off:i ~len:skipped with
      | Pass -> loop pending (i + skipped)
      | Stream_error _ as error ->
          loop (remember_stream_error pending error) (i + skipped)
      | Connection_error _ | Policy_close _ as error -> error)
    else
      let needed = Frame.header_size - t.header_len in
      let take = min needed (stop - i) in
      for j = 0 to take - 1 do
        Bytes.set t.header (t.header_len + j) (Bigstringaf.get bs (i + j))
      done;
      t.header_len <- t.header_len + take;
      if t.header_len = Frame.header_size then
        match start_frame t with
        | Pass -> loop pending (i + take)
        | Stream_error _ as error ->
            loop (remember_stream_error pending error) (i + take)
        | Connection_error _ | Policy_close _ as error -> error
      else loop pending (i + take)
  in
  loop Pass off

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
