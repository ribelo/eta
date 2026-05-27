module Error = Error

type config = {
  max_settings_per_connection : int;
  max_goaway_per_connection : int;
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
	  response_headers_seen_by_stream : (int, int) Hashtbl.t;
	  mutable header_block_bytes : int;
	  mutable header_block_frames : int;
	}

let create ?(config = default_config) () =
  {
    config;
    header = Bytes.create 9;
    header_len = 0;
	    payload_remaining = 0;
	    settings_seen = 0;
	    goaway_seen = 0;
	    response_headers_seen_by_stream = Hashtbl.create 32;
	    header_block_bytes = 0;
	    header_block_frames = 0;
	  }

let byte t index = Char.code (Bytes.get t.header index)

let frame_length t =
  (byte t 0 lsl 16) lor (byte t 1 lsl 8) lor byte t 2

let frame_type t = byte t 3
let frame_flags t = byte t 4
let stream_id t =
  ((byte t 5 land 0x7f) lsl 24)
  lor (byte t 6 lsl 16) lor (byte t 7 lsl 8) lor byte t 8
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

let account_header_bytes t ~frame_type ~flags ~length ~stream_id =
  match frame_type with
  | 0x1 ->
      t.header_block_bytes <- length;
      t.header_block_frames <- 1;
      (match account_response_headers t stream_id with
      | Some error -> Some error
      | None when length > t.config.max_hpack_block_bytes ->
        Some
          (Error.Hpack_decode_overflow
             {
               decoded_bytes = length;
               limit_bytes = t.config.max_hpack_block_bytes;
             })
      | None when end_headers flags -> (
        reset_header_block t;
        None)
      | None -> None)
  | 0x9 ->
      t.header_block_bytes <- t.header_block_bytes + length;
      t.header_block_frames <- t.header_block_frames + 1;
      if t.header_block_bytes > t.config.max_continuation_accumulator_bytes then
        Some
          (Error.Continuation_flood
             {
               accumulated_bytes = t.header_block_bytes;
               limit_bytes = t.config.max_continuation_accumulator_bytes;
               frames = t.header_block_frames;
             })
      else if end_headers flags then (
        reset_header_block t;
        None)
      else None
  | _ -> None

let start_frame t =
  let length = frame_length t in
  let frame_type = frame_type t in
  let flags = frame_flags t in
  let stream_id = stream_id t in
  t.header_len <- 0;
  t.payload_remaining <- length;
  match frame_type with
  | 0x4 -> account_settings t
  | 0x7 -> account_goaway t
  | 0x1 | 0x9 -> account_header_bytes t ~frame_type ~flags ~length ~stream_id
  | _ -> None

let observe_byte t byte =
  if t.payload_remaining > 0 then (
    t.payload_remaining <- t.payload_remaining - 1;
    None)
  else (
    Bytes.set t.header t.header_len byte;
    t.header_len <- t.header_len + 1;
    if t.header_len = 9 then start_frame t else None)

let observe t bs ~off ~len =
  let stop = off + len in
  let rec loop i =
    if i >= stop then None
    else if t.payload_remaining > 0 then (
      let skipped = min t.payload_remaining (stop - i) in
      t.payload_remaining <- t.payload_remaining - skipped;
      loop (i + skipped))
    else
      let needed = 9 - t.header_len in
      let take = min needed (stop - i) in
      for j = 0 to take - 1 do
        Bytes.set t.header (t.header_len + j) (Bigstringaf.get bs (i + j))
      done;
      t.header_len <- t.header_len + take;
      if t.header_len = 9 then
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
