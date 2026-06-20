(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

(* Initial server connection implementation. Supports the basic request/response
   path used by the existing eta_http_eio adapter: preface handshake, SETTINGS,
   HEADERS (single frame), DATA, WINDOW_UPDATE, RST_STREAM, GOAWAY, and both
   fixed and streaming responses. Continuation frames, PUSH_PROMISE, and
   priority reparenting are accepted as no-ops or handled minimally. *)

type error = {
  error_code : Error_code.t;
  message : string;
}

type 'a iovec = {
  buffer : 'a;
  off : int;
  len : int;
}

type write_operation =
  | Write of Bigstringaf.t iovec list
  | Yield
  | Close of int

type conn_state =
  | Open
  | Half_closed
  | Closing of Error_code.t
  | Closed

type server_request = {
  stream_id : int;
  meth : string;
  scheme : string;
  authority : string option;
  path : string;
  headers : (string * string) list;
  body : Body.Reader.t;
}

type server_response = {
  status : int;
  headers : (string * string) list;
  body : [ `Empty | `String of string | `Reader of Body.Reader.t ];
  trailers : (string * string) list Lazy.t;
}

type client_request = {
  meth : string;
  scheme : string option;
  authority : string option;
  path : string;
  headers : (string * string) list;
}

type client_response = {
  status : int;
  headers : (string * string) list;
  body : Body.Reader.t;
}

type reqd = {
  connection : t;
  stream : Stream.t;
  request : server_request;
  mutable response : server_response option;
  mutable response_body_kind :
    [ `Empty | `String of string | `Streaming of Body.Writer.t ];
  mutable trailers_opt : (string * string) list Lazy.t option;
  mutable responded : bool;
}

and server_state = {
  request_handler : reqd -> unit;
  error_handler : error -> unit;
}

and client_stream = {
  request : client_request;
  response_body : Body.Reader.t;
  error_handler : Stream.id -> error -> unit;
  response_handler : Stream.id -> client_response -> unit;
  trailers_handler : ((string * string) list -> unit) option;
  mutable response_started : bool;
}

and client_state = {
  client_error_handler : error -> unit;
  client_streams : (int, client_stream) Hashtbl.t;
}

and role =
  | Server of server_state
  | Client of client_state

and t = {
  role : role;
  mutable state : conn_state;
  mutable peer_settings : Settings.t;
  local_settings : Settings.t;
  streams : (int, Stream.t) Hashtbl.t;
  scheduler : Scheduler.t;
  scheduler_refs : (int, Scheduler.ref) Hashtbl.t;
  mutable max_client_stream_id : int;
  mutable max_server_stream_id : int;
  mutable current_client_streams : int;
  mutable unacked_settings : int;
  mutable did_send_goaway : bool;
  mutable last_stream_id : int;
  recv_window : Window.t;
  send_window : Window.t;
  hpack_decoder : Hpack.t;
  hpack_encoder : Hpack.encoder;
  read_buf : buf;
  write_buf : buf;
  mutable yield_callback : (unit -> unit) option;
  mutable read_state : read_state;
}

and buf = {
  mutable data : Bigstringaf.t;
  mutable off : int;
  mutable len : int;
}

and read_state =
  | Expect_preface
  | Expect_frame
  | Expect_continuation of {
      stream_id : int;
      acc : Buffer.t;
    }

(* -------------------------------------------------------------------------- *)
(* Buffer helpers *)

let max a b = if a >= b then a else b

let ensure_capacity b need =
  let available = Bigstringaf.length b.data - b.off - b.len in
  if available < need then (
    let required = b.len + need in
    let new_cap = max required (Bigstringaf.length b.data * 2) in
    let new_data = Bigstringaf.create new_cap in
    if b.len > 0 then
      Bigstringaf.blit b.data ~src_off:b.off new_data ~dst_off:0 ~len:b.len;
    b.data <- new_data;
    b.off <- 0)

let shift b n =
  if n < 0 || n > b.len then invalid_arg "Connection.shift";
  b.off <- b.off + n;
  b.len <- b.len - n;
  if b.len = 0 then b.off <- 0

let append_string b s =
  let slen = String.length s in
  if slen > 0 then (
    ensure_capacity b slen;
    Bigstringaf.blit_from_string s ~src_off:0 b.data ~dst_off:(b.off + b.len)
      ~len:slen;
    b.len <- b.len + slen)

let append_substring b s ~src_off ~len =
  if len > 0 then (
    ensure_capacity b len;
    Bigstringaf.blit_from_string s ~src_off b.data ~dst_off:(b.off + b.len)
      ~len;
    b.len <- b.len + len)

let append_bigstring b src ~src_off ~len =
  if len > 0 then (
    ensure_capacity b len;
    Bigstringaf.blit src ~src_off b.data ~dst_off:(b.off + b.len) ~len;
    b.len <- b.len + len)

let ensure_capacity_limited b ~limit need =
  if b.len + need > limit then invalid_arg "Connection.ensure_capacity_limited";
  let available = Bigstringaf.length b.data - b.off - b.len in
  if available < need then (
    let required = b.len + need in
    let doubled = Bigstringaf.length b.data * 2 in
    let new_cap = min limit (max required doubled) in
    let new_data = Bigstringaf.create new_cap in
    if b.len > 0 then
      Bigstringaf.blit b.data ~src_off:b.off new_data ~dst_off:0 ~len:b.len;
    b.data <- new_data;
    b.off <- 0)

let append_bigstring_limited b ~limit src ~src_off ~len =
  if len > 0 then (
    ensure_capacity_limited b ~limit len;
    Bigstringaf.blit src ~src_off b.data ~dst_off:(b.off + b.len) ~len;
    b.len <- b.len + len)

let[@zero_alloc] byte n = Char.chr (n land 0xff)

(* Write a 9-byte HTTP/2 frame header directly into the bigstring write buffer,
   avoiding the [String.init]-allocated header that [Frame.header] returns. *)
let append_frame_header b ~length ~frame_type ~flags ~stream_id =
  ensure_capacity b 9;
  let data = b.data in
  let base = b.off + b.len in
  let set i c = Bigstringaf.unsafe_set data (base + i) c in
  let ft = Frame.frame_type_code frame_type in
  set 0 (byte (length lsr 16));
  set 1 (byte (length lsr 8));
  set 2 (byte length);
  set 3 (byte ft);
  set 4 (byte flags);
  set 5 (byte (stream_id lsr 24));
  set 6 (byte (stream_id lsr 16));
  set 7 (byte (stream_id lsr 8));
  set 8 (byte stream_id);
  b.len <- b.len + 9

(* -------------------------------------------------------------------------- *)
(* Constructors *)

let default_settings = Settings.host_default
let max_connection_recv_window = 0x7fffffff

let create_connection ?(config = default_settings) role =
  let hpack_capacity = config.header_table_size in
  {
    role;
    state = Open;
    peer_settings = Settings.default;
    local_settings = config;
    streams = Hashtbl.create 64;
    scheduler = Scheduler.create ();
    scheduler_refs = Hashtbl.create 64;
    max_client_stream_id = 0;
    max_server_stream_id = 0;
    current_client_streams = 0;
    unacked_settings = 0;
    did_send_goaway = false;
    last_stream_id = 0;
    recv_window = Window.create ~initial:Settings.default.initial_window_size;
    send_window = Window.create ~initial:Settings.default.initial_window_size;
    hpack_decoder = Hpack.create hpack_capacity;
    hpack_encoder = Hpack.encoder_create hpack_capacity;
    read_buf = { data = Bigstringaf.create 4096; off = 0; len = 0 };
    write_buf = { data = Bigstringaf.create 4096; off = 0; len = 0 };
    yield_callback = None;
    read_state =
      (match role with Server _ -> Expect_preface | Client _ -> Expect_frame);
  }

(* -------------------------------------------------------------------------- *)
(* Output frame helpers *)

let wake_writer t =
  match t.yield_callback with
  | Some f ->
      t.yield_callback <- None;
      f ()
  | None -> ()

let send_raw t s =
  if t.state <> Closed then (
    append_string t.write_buf s;
    wake_writer t)

(* Append a frame header string followed by a bigstring payload directly into
   the write buffer, avoiding the per-frame [Bigstringaf.substring] body copy
   and the [header ^ body] concatenation. *)
(* Append a frame header followed by a bigstring payload directly into the
   write buffer, with no per-frame header string or payload-copy allocation. *)
let send_frame_with_bigstring t ~length ~frame_type ~flags ~stream_id buf ~off =
  if t.state <> Closed then (
    append_frame_header t.write_buf ~length ~frame_type ~flags ~stream_id;
    append_bigstring t.write_buf buf ~src_off:off ~len:length;
    wake_writer t)

(* Append a frame header followed by a slice of a string payload directly into
   the write buffer (HEADERS/CONTINUATION path). *)
let send_frame_with_substring t ~length ~frame_type ~flags ~stream_id s ~off =
  if t.state <> Closed then (
    append_frame_header t.write_buf ~length ~frame_type ~flags ~stream_id;
    append_substring t.write_buf s ~src_off:off ~len:length;
    wake_writer t)

(* Append a payload-less frame header directly into the write buffer. *)
let send_frame_header_only t ~length ~frame_type ~flags ~stream_id =
  if t.state <> Closed then (
    append_frame_header t.write_buf ~length ~frame_type ~flags ~stream_id;
    wake_writer t)

let send_window_update_frame t stream_id increment =
  let header =
    Frame.header ~length:4 ~frame_type:Frame.Window_update
      ~flags:Frame.Flags.empty ~stream_id
  in
  send_raw t (header ^ Frame.uint32 increment)

let send_window_update t stream_id window increment =
  if increment > 0 then
    match Window.update window increment with
    | Ok () -> send_window_update_frame t stream_id increment
    | Error _ ->
        invalid_arg
          "Eta_http_h2.Connection.send_window_update: receive window overflow"

let refresh_connection_recv_window t =
  let available = Window.available t.recv_window in
  if available <= max_connection_recv_window / 2 then
    send_window_update t 0 t.recv_window (max_connection_recv_window - available)

let send_settings t settings =
  let payload = Settings.encode settings in
  let header =
    Frame.header ~length:(String.length payload) ~frame_type:Frame.Settings
      ~flags:Frame.Flags.empty ~stream_id:0
  in
  t.unacked_settings <- t.unacked_settings + 1;
  send_raw t (header ^ payload)

let send_settings_ack t =
  let header =
    Frame.header ~length:0 ~frame_type:Frame.Settings ~flags:Frame.Flags.ack
      ~stream_id:0
  in
  send_raw t header

let send_goaway t ~last_stream_id error_code debug_data =
  let payload_len = 8 + String.length debug_data in
  let header =
    Frame.header ~length:payload_len ~frame_type:Frame.Goaway
      ~flags:Frame.Flags.empty ~stream_id:0
  in
  send_raw t
    (header
    ^ Frame.uint32 (last_stream_id land 0x7fffffff)
    ^ Frame.uint32 (Error_code.to_int error_code)
    ^ debug_data);
  t.did_send_goaway <- true

let send_rst_stream t stream_id error_code =
  let header =
    Frame.header ~length:4 ~frame_type:Frame.Rst_stream
      ~flags:Frame.Flags.empty ~stream_id
  in
  send_raw t (header ^ Frame.uint32 (Error_code.to_int error_code))

(* -------------------------------------------------------------------------- *)
(* Error reporting *)

let report_error t err =
  (match t.role with
  | Server s -> s.error_handler err
  | Client c -> c.client_error_handler err);
  if not t.did_send_goaway then (
    t.state <- Closing err.error_code;
    send_goaway t ~last_stream_id:t.last_stream_id err.error_code err.message)

(* -------------------------------------------------------------------------- *)
(* Stream lifecycle *)

let open_stream t ~id =
  let stream =
    Stream.create ~id ~initial_send_window:t.peer_settings.initial_window_size
      ~initial_recv_window:t.local_settings.initial_window_size
  in
  Body.Reader.set_consume_fn (Stream.request_body stream) (fun len ->
      match Stream.note_recv_window_consumed stream len with
      | None -> ()
      | Some increment ->
          send_window_update t id (Stream.recv_window stream) increment);
  Hashtbl.replace t.streams id stream;
  let ref =
    Scheduler.open_ref ~id ~parent:t.scheduler ~weight:16 ~exclusive:false
  in
  Hashtbl.replace t.scheduler_refs id ref;
  stream

let close_stream t id =
  Hashtbl.remove t.streams id;
  match Hashtbl.find_opt t.scheduler_refs id with
  | Some ref ->
      Scheduler.close_ref ref;
      Hashtbl.remove t.scheduler_refs id
  | None -> ()

let retire_stream t stream =
  close_stream t (Stream.id stream);
  (match t.role with
  | Client c -> Hashtbl.remove c.client_streams (Stream.id stream)
  | Server _ -> ());
  t.current_client_streams <- max 0 (t.current_client_streams - 1)

let maybe_retire_stream t stream =
  if Stream.sent_end_stream stream && Stream.recv_end_stream stream then
    retire_stream t stream

let reset_stream t stream_id error_code =
  send_rst_stream t stream_id error_code;
  match Hashtbl.find_opt t.streams stream_id with
  | None -> ()
  | Some stream ->
      Stream.reset stream ~error_code;
      retire_stream t stream

let report_stream_error t stream_id error_code =
  reset_stream t stream_id error_code

(* -------------------------------------------------------------------------- *)
(* Response helpers *)

let hpack_header name value = { Hpack.name; value; sensitive = false }

let encode_header_list t headers =
  Hpack.encode_headers t.hpack_encoder
    (List.map (fun (n, v) -> hpack_header n v) headers)

let encode_headers t headers status =
  Hpack.encode_response_headers t.hpack_encoder ~status headers

let encode_trailers t headers = encode_header_list t headers

let send_header_block t ~stream_id ~end_stream header_block =
  let max_frame_size = t.peer_settings.max_frame_size in
  let total = String.length header_block in
  let rec loop off first =
    let remaining = total - off in
    if remaining <= max_frame_size then
      let flags =
        Frame.Flags.end_headers
        lor (if first && end_stream then Frame.Flags.end_stream else 0)
      in
      let frame_type = if first then Frame.Headers else Frame.Continuation in
      send_frame_with_substring t ~length:remaining ~frame_type ~flags
        ~stream_id header_block ~off
    else
      let flags =
        if first && end_stream then Frame.Flags.end_stream else 0
      in
      let frame_type = if first then Frame.Headers else Frame.Continuation in
      send_frame_with_substring t ~length:max_frame_size ~frame_type ~flags
        ~stream_id header_block ~off;
      loop (off + max_frame_size) false
  in
  loop 0 true

let send_response_headers t stream (response : server_response) =
  let header_block = encode_headers t response.headers response.status in
  let end_stream =
    match response.body with `Empty -> true | `String _ | `Reader _ -> false
  in
  send_header_block t ~stream_id:(Stream.id stream) ~end_stream header_block

let wake_schedulable_stream t stream =
  (match Hashtbl.find_opt t.scheduler_refs (Stream.id stream) with
  | Some ref -> Scheduler.activate t.scheduler ref
  | None -> ());
  wake_writer t

let stream_has_outbound_work stream =
  Stream.total_pending stream > 0
  || (Stream.send_end_stream stream && not (Stream.sent_end_stream stream))

let wake_send_window_available_streams t =
  Hashtbl.iter
    (fun _ stream ->
      if
        stream_has_outbound_work stream
        && (Stream.total_pending stream = 0
           || Window.available (Stream.send_window stream) > 0)
      then wake_schedulable_stream t stream)
    t.streams

let response_declares_empty_body (response : server_response) =
  match response.body with `Empty -> true | `String _ | `Reader _ -> false

let rec respond reqd response body_kind =
  if reqd.responded then
    invalid_arg "Eta_http_h2.Connection.Server.Reqd.respond: already responded";
  reqd.responded <- true;
  reqd.response <- Some response;
  reqd.response_body_kind <- body_kind;
  let stream = reqd.stream in
  let conn = reqd.connection in
  send_response_headers conn stream response;
  (match body_kind with
  | `String s ->
      if response_declares_empty_body response then (
        if String.length s <> 0 then
          invalid_arg
            "Eta_http_h2.Connection.Server.Reqd.respond_with_string: empty \
             response body cannot carry bytes";
        Stream.mark_send_end_stream stream;
        Stream.mark_sent_end_stream stream;
        maybe_retire_stream conn stream)
      else (
      if String.length s > 0 then
        ignore
          (Stream.queue_data stream
             (Bigstringaf.of_string ~off:0 ~len:(String.length s) s)
             ~off:0 ~len:(String.length s));
      Stream.mark_send_end_stream stream)
  | `Empty ->
      Stream.mark_send_end_stream stream;
      Stream.mark_sent_end_stream stream;
      maybe_retire_stream conn stream
  | `Streaming writer ->
      if response_declares_empty_body response then
        invalid_arg
          "Eta_http_h2.Connection.Server.Reqd.respond_with_streaming: empty \
           response body cannot stream";
      Body.Writer.set_write_fn writer (fun buf ~off ~len ->
          ignore (Stream.queue_data stream buf ~off ~len);
          wake_schedulable_stream conn stream);
      Body.Writer.set_flush_fn writer (fun fn -> Stream.on_drained stream fn);
      Body.Writer.set_close_callback writer (fun () ->
          Stream.mark_send_end_stream stream;
          wake_schedulable_stream conn stream));
  wake_schedulable_stream conn stream

(* -------------------------------------------------------------------------- *)
(* Frame handlers *)

let handle_settings t ~flags payload =
  if flags land Frame.Flags.ack <> 0 then (
    if String.length payload <> 0 then
      report_error t
        { error_code = Error_code.Frame_size_error;
          message = "SETTINGS ACK with non-empty payload" }
    else if t.unacked_settings > 0 then
      t.unacked_settings <- t.unacked_settings - 1)
  else
    let envelope =
      { Frame.length = String.length payload;
        frame_type = Frame.frame_type_code Frame.Settings;
        flags;
        stream_id = 0
      }
    in
    match
      Frame.Settings.decode t.read_buf.data
        ~off:(t.read_buf.off + Frame.header_size)
        ~envelope
    with
    | Error code ->
        report_error t
          { error_code = code; message = "SETTINGS decode error" }
    | Ok settings_list ->
        let new_settings =
          List.fold_left Settings.apply_setting t.peer_settings settings_list
        in
        (match Settings.validate new_settings with
        | Error code ->
            report_error t
              { error_code = code; message = "invalid peer SETTINGS" }
        | Ok () ->
            let old_initial_window = t.peer_settings.initial_window_size in
            t.peer_settings <- new_settings;
            Hpack.encoder_set_max_table_size t.hpack_encoder
              new_settings.header_table_size;
            send_settings_ack t;
            let delta = new_settings.initial_window_size - old_initial_window in
            if delta <> 0 then
              Hashtbl.iter
                (fun _ stream ->
                  ignore
                    (Window.update (Stream.send_window stream) delta))
                t.streams;
            if delta > 0 then wake_send_window_available_streams t)

let handle_server_headers t ~flags ~stream_id payload =
  if stream_id = 0 then
    report_error t
      { error_code = Error_code.Protocol_error;
        message = "HEADERS frame with stream_id=0" }
  else if stream_id land 1 = 0 then
    send_rst_stream t stream_id Error_code.Protocol_error
  else if stream_id <= t.max_client_stream_id then
    (* trailing headers or late frame; ignore for now *)
    ()
  else if t.state <> Open then
    send_rst_stream t stream_id Error_code.Refused_stream
  else (
    t.max_client_stream_id <- stream_id;
    t.last_stream_id <- stream_id;
    if t.current_client_streams + 1 > t.local_settings.max_concurrent_streams then
      send_rst_stream t stream_id Error_code.Refused_stream
    else
      let stream = open_stream t ~id:stream_id in
      t.current_client_streams <- t.current_client_streams + 1;
      (match Hpack.decode_headers_string t.hpack_decoder payload with
      | Error _ ->
          reset_stream t stream_id Error_code.Compression_error
      | Ok headers ->
          let meth = List.assoc_opt ":method" headers in
          let scheme = List.assoc_opt ":scheme" headers in
          let authority = List.assoc_opt ":authority" headers in
          let path = List.assoc_opt ":path" headers in
          let request_shape =
            match meth with
            | Some meth when String.equal meth "CONNECT" ->
                Some
                  ( meth,
                    Option.value ~default:"" scheme,
                    Option.value ~default:"" path )
            | Some meth -> (
                match (scheme, path) with
                | Some scheme, Some path -> Some (meth, scheme, path)
                | _ -> None)
            | None -> None
          in
          match request_shape with
          | Some (meth, scheme, path) ->
              let request : server_request =
                { stream_id;
                  meth;
                  scheme;
                  authority;
                  path;
                  headers;
                  body = Stream.request_body stream
                }
              in
              let reqd =
                { connection = t;
                  stream;
                  request;
                  response = None;
                  response_body_kind = `Empty;
                  trailers_opt = None;
                  responded = false
                }
              in
              if flags land Frame.Flags.end_stream <> 0 then
                Stream.mark_recv_end_stream stream;
              if flags land Frame.Flags.end_stream <> 0 then
                Body.Reader.feed_eof (Stream.request_body stream);
              maybe_retire_stream t stream;
              (match t.role with
              | Server s -> s.request_handler reqd
              | Client _ -> ())
          | None ->
              reset_stream t stream_id Error_code.Protocol_error))

let header_value name headers = List.assoc_opt name headers

let strip_pseudo_headers headers =
  List.filter
    (fun (name, _) ->
      String.length name = 0 || not (Char.equal name.[0] ':'))
    headers

let client_stream_error t stream_id error_code message =
  (match t.role with
  | Client c -> (
      match Hashtbl.find_opt c.client_streams stream_id with
      | None -> ()
      | Some state -> state.error_handler stream_id { error_code; message })
  | Server _ -> ());
  reset_stream t stream_id error_code

let finish_inbound_body t _stream_id stream =
  Stream.mark_recv_end_stream stream;
  Body.Reader.feed_eof (Stream.request_body stream);
  maybe_retire_stream t stream

let handle_client_headers t c ~flags ~stream_id payload =
  if stream_id = 0 then
    report_error t
      { error_code = Error_code.Protocol_error;
        message = "HEADERS frame with stream_id=0" }
  else if stream_id land 1 = 0 then
    report_error t
      { error_code = Error_code.Protocol_error;
        message = "server HEADERS on even stream id" }
  else if stream_id > t.max_client_stream_id then
    report_error t
      { error_code = Error_code.Protocol_error;
        message = "server HEADERS on unopened stream" }
  else
    let stream = Hashtbl.find_opt t.streams stream_id in
    let client_stream = Hashtbl.find_opt c.client_streams stream_id in
    match Hpack.decode_headers_string t.hpack_decoder payload with
    | Error _ ->
        client_stream_error t stream_id Error_code.Compression_error
          "response HPACK decode error"
    | Ok headers -> (
        match (stream, client_stream) with
        | None, _ ->
            (* Closed streams can still carry frames already in flight. Keep the
               HPACK table synchronized by decoding, then ignore them. *)
            ()
        | Some stream, Some client_stream when client_stream.response_started ->
            if flags land Frame.Flags.end_stream = 0 then
              client_stream_error t stream_id Error_code.Protocol_error
                "response trailers without END_STREAM"
            else (
              Option.iter (fun f -> f (strip_pseudo_headers headers))
                client_stream.trailers_handler;
              finish_inbound_body t stream_id stream)
        | Some stream, Some client_stream -> (
            match header_value ":status" headers with
            | None ->
                client_stream_error t stream_id Error_code.Protocol_error
                  "response HEADERS missing :status"
            | Some status_text -> (
                match int_of_string_opt status_text with
                | None ->
                    client_stream_error t stream_id Error_code.Protocol_error
                      "response HEADERS invalid :status"
                | Some 101 ->
                    client_stream_error t stream_id Error_code.Protocol_error
                      "response HEADERS invalid 101 status"
                | Some status when status >= 100 && status < 200 ->
                    ()
                | Some status ->
                    client_stream.response_started <- true;
                    let response : client_response =
                      {
                        status;
                        headers = strip_pseudo_headers headers;
                        body = client_stream.response_body;
                      }
                    in
                    if flags land Frame.Flags.end_stream <> 0 then
                      finish_inbound_body t stream_id stream;
                    client_stream.response_handler stream_id response))
        | Some _, None -> ())

let handle_headers t ~flags ~stream_id payload =
  match t.role with
  | Server _ -> handle_server_headers t ~flags ~stream_id payload
  | Client c -> handle_client_headers t c ~flags ~stream_id payload

let handle_data t ~flags ~stream_id payload =
  if stream_id = 0 then
    report_error t
      { error_code = Error_code.Protocol_error;
        message = "DATA frame with stream_id=0" }
  else
    let len = String.length payload in
    match Window.consume t.recv_window len with
    | Error code ->
        report_error t
          { error_code = code; message = "connection receive window exhausted" }
    | Ok () -> (
        refresh_connection_recv_window t;
        match Hashtbl.find_opt t.streams stream_id with
        | None ->
            if stream_id > t.max_client_stream_id then
              report_error t
                { error_code = Error_code.Protocol_error;
                  message = "DATA frame on unopened stream" }
        | Some stream -> (
            let allow_data =
              match t.role with
              | Server _ -> true
              | Client c -> (
                  match Hashtbl.find_opt c.client_streams stream_id with
                  | Some client_stream when client_stream.response_started ->
                      true
                  | Some _ ->
                      client_stream_error t stream_id Error_code.Protocol_error
                        "DATA before response HEADERS";
                      false
                  | None -> false)
            in
            if allow_data then
              match Window.consume (Stream.recv_window stream) len with
              | Error code -> reset_stream t stream_id code
              | Ok () ->
                  if len > 0 then
                    Body.Reader.feed (Stream.request_body stream)
                      (Bigstringaf.of_string ~off:0 ~len payload)
                      ~off:0 ~len;
                  if flags land Frame.Flags.end_stream <> 0 then
                    finish_inbound_body t stream_id stream))

let handle_window_update t ~stream_id increment =
  if increment <= 0 then
    if stream_id = 0 then
      report_error t
        { error_code = Error_code.Protocol_error;
          message = "WINDOW_UPDATE increment zero on connection" }
    else send_rst_stream t stream_id Error_code.Protocol_error
  else if stream_id = 0 then
    match Window.update t.send_window increment with
    | Error code ->
        report_error t
          { error_code = code;
            message = "connection send window overflow" }
    | Ok () -> wake_send_window_available_streams t
  else
    match Hashtbl.find_opt t.streams stream_id with
    | None ->
        (* WINDOW_UPDATE on a closed stream is harmless; the peer may be
           acknowledging data we sent before it learned the stream closed. *)
        if stream_id <= t.max_client_stream_id then ()
    | Some stream -> (
        match Window.update (Stream.send_window stream) increment with
        | Error code -> reset_stream t stream_id code
        | Ok () ->
            wake_schedulable_stream t stream)

let handle_rst_stream t ~stream_id error_code =
  match Hashtbl.find_opt t.streams stream_id with
  | None -> ()
  | Some stream ->
      (match t.role with
      | Client c -> (
          match Hashtbl.find_opt c.client_streams stream_id with
          | None -> ()
          | Some (client_stream : client_stream) ->
              client_stream.error_handler stream_id
                {
                  error_code;
                  message = "peer reset stream";
                })
      | Server _ -> ());
      Stream.reset_by_peer stream ~error_code;
      Body.Reader.close (Stream.request_body stream);
      retire_stream t stream

let handle_goaway t ~last_stream_id error_code debug_data =
  t.last_stream_id <- last_stream_id;
  if t.state = Open then t.state <- Half_closed;
  match t.role with
  | Server _ -> ()
  | Client c ->
      let message =
        if String.length debug_data = 0 then "peer sent GOAWAY"
        else "peer sent GOAWAY: " ^ debug_data
      in
      let to_retire = ref [] in
      Hashtbl.iter
        (fun stream_id (client_stream : client_stream) ->
          if stream_id > last_stream_id then (
            client_stream.error_handler stream_id { error_code; message };
            to_retire := stream_id :: !to_retire))
        c.client_streams;
      List.iter
        (fun stream_id ->
          match Hashtbl.find_opt t.streams stream_id with
          | None -> Hashtbl.remove c.client_streams stream_id
          | Some stream ->
              Stream.reset_by_peer stream ~error_code;
              Body.Reader.close (Stream.request_body stream);
              retire_stream t stream)
        !to_retire

let handle_ping t ~flags payload =
  if flags land Frame.Flags.ack = 0 then
    let header =
      Frame.header ~length:8 ~frame_type:Frame.Ping ~flags:Frame.Flags.ack
        ~stream_id:0
    in
    send_raw t (header ^ payload)

(* -------------------------------------------------------------------------- *)
(* Preface handling *)

let preface_string = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

let process_preface t =
  let b = t.read_buf in
  let plen = String.length preface_string in
  if b.len < plen then 0
  else
    let got = Bigstringaf.substring b.data ~off:b.off ~len:plen in
    if got <> preface_string then (
      report_error t
        { error_code = Error_code.Protocol_error;
          message = "invalid HTTP/2 connection preface" };
      0)
    else (
      t.read_state <- Expect_frame;
      send_settings t t.local_settings;
      (* Bump the connection receive window to the RFC maximum so that stream-level
         flow control is the limiting factor, without exceeding 2^31-1. *)
      send_window_update t 0 t.recv_window
        (max_connection_recv_window - Settings.default.initial_window_size);
      plen)

let send_client_preface t =
  send_raw t preface_string;
  send_settings t t.local_settings;
  send_window_update t 0 t.recv_window
    (max_connection_recv_window - Settings.default.initial_window_size)

(* -------------------------------------------------------------------------- *)
(* Frame dispatch *)

let parse_envelope t =
  if t.read_buf.len < Frame.header_size then None
  else
    Some
      (Frame.parse_header_string
         (Bigstringaf.substring t.read_buf.data ~off:t.read_buf.off
            ~len:Frame.header_size)
         ~off:0)

let max_read_buffer_size t =
  max (String.length preface_string)
    (Frame.header_size + t.local_settings.max_frame_size)

let process_frame t =
  match parse_envelope t with
  | None -> 0
  | Some env ->
      t.last_stream_id <- max t.last_stream_id env.stream_id;
      if env.length > t.local_settings.max_frame_size then (
        report_error t
          { error_code = Error_code.Frame_size_error;
            message =
              Printf.sprintf
                "HTTP/2 frame length %d exceeds advertised maximum %d"
                env.length t.local_settings.max_frame_size
          };
        Frame.header_size)
      else if env.length > t.read_buf.len - Frame.header_size then 0
      else
        let payload_off = t.read_buf.off + Frame.header_size in
        let payload =
          Bigstringaf.substring t.read_buf.data ~off:payload_off ~len:env.length
        in
        (match Frame.frame_type_of_code env.frame_type with
        | Frame.Settings -> handle_settings t ~flags:env.flags payload
        | Frame.Headers ->
            handle_headers t ~flags:env.flags ~stream_id:env.stream_id payload
        | Frame.Data ->
            handle_data t ~flags:env.flags ~stream_id:env.stream_id payload
        | Frame.Window_update ->
            (match
               Frame.Window_update.decode t.read_buf.data ~off:payload_off
                 ~envelope:env
             with
            | Error (code, _) ->
                if env.stream_id = 0 then
                  report_error t
                    { error_code = code;
                      message = "WINDOW_UPDATE decode error" }
                else reset_stream t env.stream_id code
            | Ok { window_size_increment } ->
                handle_window_update t ~stream_id:env.stream_id
                  window_size_increment)
        | Frame.Rst_stream ->
            (match
               Frame.Rst_stream.decode t.read_buf.data ~off:payload_off
                 ~envelope:env
             with
            | Error code ->
                if env.stream_id = 0 then
                  report_error t
                    { error_code = code;
                      message = "RST_STREAM decode error" }
                else reset_stream t env.stream_id code
            | Ok { error_code } ->
                handle_rst_stream t ~stream_id:env.stream_id error_code)
        | Frame.Goaway ->
            (match
               Frame.Goaway.decode t.read_buf.data ~off:payload_off
                 ~envelope:env
             with
            | Error code ->
                report_error t
                  { error_code = code; message = "GOAWAY decode error" }
            | Ok { last_stream_id; error_code; debug_data; off; len } ->
                let debug =
                  Bigstringaf.substring debug_data ~off ~len
                in
                handle_goaway t ~last_stream_id error_code debug)
        | Frame.Ping ->
            (match
               Frame.Ping.decode t.read_buf.data ~off:payload_off
                 ~envelope:env
             with
            | Error _ -> ()
            | Ok { payload } ->
                handle_ping t ~flags:env.flags (Bytes.to_string payload))
        | _ -> (* Ignore unknown/extension frames. *) ());
        Frame.header_size + env.length

let rec process_input t =
  match t.state with
  | Closed | Closing _ -> ()
  | Open | Half_closed ->
    match t.read_state with
    | Expect_preface ->
        let consumed = process_preface t in
        if consumed > 0 then (
          shift t.read_buf consumed;
          process_input t)
    | Expect_frame ->
        let consumed = process_frame t in
        if consumed > 0 then (
          shift t.read_buf consumed;
          process_input t)
    | Expect_continuation _ ->
        let consumed = process_frame t in
        if consumed > 0 then (
          shift t.read_buf consumed;
          process_input t)

(* -------------------------------------------------------------------------- *)
(* Public API *)

let report_read_buffer_exhausted t =
  report_error t
    { error_code = Error_code.Frame_size_error;
      message =
        Printf.sprintf
          "HTTP/2 read buffer reached %d bytes without a complete frame"
          (max_read_buffer_size t)
    }

let rec read_loop t buf ~off ~len consumed =
  if consumed >= len then consumed
  else
    match t.state with
    | Closed | Closing _ ->
        (* After GOAWAY has been queued, any additional transport bytes are
           irrelevant to this state machine. Treat them as consumed so the
           adapter can drain its own buffer and let the writer close cleanly. *)
        len
    | Open | Half_closed ->
        process_input t;
        (match t.state with
        | Closed | Closing _ -> len
        | Open | Half_closed ->
            let capacity = max_read_buffer_size t - t.read_buf.len in
            if capacity <= 0 then (
              report_read_buffer_exhausted t;
              len)
            else
              let take = min (len - consumed) capacity in
              append_bigstring_limited t.read_buf
                ~limit:(max_read_buffer_size t) buf
                ~src_off:(off + consumed) ~len:take;
              process_input t;
              read_loop t buf ~off ~len (consumed + take))

let read t buf ~off ~len =
  if len < 0 then invalid_arg "Connection.read: negative len";
  read_loop t buf ~off ~len 0

let read_eof t buf ~off ~len =
  let n = read t buf ~off ~len in
  if t.state = Open || t.state = Half_closed then (
    let incomplete =
      t.read_buf.len > 0
      ||
      match t.read_state with
      | Expect_continuation _ -> true
      | Expect_preface | Expect_frame -> false
    in
    if incomplete then
      report_error t
        { error_code = Error_code.Protocol_error;
          message = "transport EOF with incomplete HTTP/2 frame"
        }
    else (
      if t.state = Open then t.state <- Half_closed;
      if not t.did_send_goaway then
        send_goaway t ~last_stream_id:t.last_stream_id Error_code.No_error ""));
  n

(* Write path *)

let emit_final_stream_frame t stream =
  (match Stream.take_trailers stream with
  | Some trailers ->
      let header_block = encode_trailers t trailers in
      send_header_block t ~stream_id:(Stream.id stream) ~end_stream:true
        header_block
  | None ->
      send_frame_header_only t ~length:0 ~frame_type:Frame.Data
        ~flags:Frame.Flags.end_stream ~stream_id:(Stream.id stream));
  Stream.mark_sent_end_stream stream;
  maybe_retire_stream t stream

let emit_stream_data t stream ref =
  if Stream.is_closed stream then `Continue false
  else if Stream.sent_end_stream stream then (
    maybe_retire_stream t stream;
    `Continue false)
  else if Stream.total_pending stream = 0 then
    if Stream.send_end_stream stream then (
      emit_final_stream_frame t stream;
      `Continue false)
    else `Continue false
  else
    let max_payload =
      min t.peer_settings.max_frame_size (Window.available t.send_window)
    in
    if max_payload <= 0 then `Stop
    else
      match Stream.take_pending_data stream ~max_len:max_payload with
      | None ->
          if Stream.total_pending stream > 0 then
            (* DATA is pending but the stream-level send window is exhausted.
               Keep END_STREAM queued until WINDOW_UPDATE makes bytes writable. *)
            `Continue false
          else if Stream.send_end_stream stream then (
            emit_final_stream_frame t stream;
            `Continue false)
          else `Continue false
      | Some (buf, off, len) -> (
          match Window.consume t.send_window len with
          | Error _ -> `Stop
          | Ok () ->
              let end_stream_now =
                Stream.send_end_stream stream
                && Stream.total_pending stream = 0
                && not (Stream.has_trailers stream)
              in
              let flags =
                if end_stream_now then Frame.Flags.end_stream
                else Frame.Flags.empty
              in
              send_frame_with_bigstring t ~length:len ~frame_type:Frame.Data
                ~flags ~stream_id:(Stream.id stream) buf ~off;
              Stream.notify_drained stream;
              if end_stream_now then (
                Stream.mark_sent_end_stream stream;
                maybe_retire_stream t stream);
              if
                Stream.total_pending stream > 0
                || (Stream.send_end_stream stream && Stream.has_trailers stream)
                || not (Stream.send_end_stream stream)
              then `Continue true
              else `Continue false)

let run_scheduler t =
  Scheduler.run t.scheduler ~f:(fun ref ->
      let id = Scheduler.id ref in
      match Hashtbl.find_opt t.streams id with
      | None -> `Continue false
      | Some stream -> emit_stream_data t stream ref)
  |> ignore

let next_write_operation t =
  if t.state = Closed then Close 0
  else (
    (match t.state with
    | Open | Half_closed -> run_scheduler t
    | Closing _ | Closed -> ());
    if t.write_buf.len > 0 then (
      Write
        [ { buffer = t.write_buf.data;
            off = t.write_buf.off;
            len = t.write_buf.len
          } ])
    else
      match t.state with
      | Half_closed when Hashtbl.length t.streams = 0 ->
          t.state <- Closed;
          Close 0
      | Closing _ ->
          t.state <- Closed;
          Close 0
      | _ -> Yield)

let has_pending_write t = t.write_buf.len > 0

let report_write_result t = function
  | `Ok n ->
      shift t.write_buf n;
      if t.write_buf.len = 0 then
        Option.iter (fun f -> f ()) t.yield_callback
  | `Closed ->
      t.state <- Closed;
      t.write_buf.len <- 0

let yield_writer t f = t.yield_callback <- Some f

let shutdown t =
  if t.state = Open || t.state = Half_closed then (
    t.state <- Closing Error_code.No_error;
    if not t.did_send_goaway then
      send_goaway t ~last_stream_id:t.last_stream_id Error_code.No_error "")

let is_closed t =
  match t.state with
  | Closing _ | Closed -> true
  | Open | Half_closed -> false

let accepts_new_streams t = t.state = Open

(* -------------------------------------------------------------------------- *)
(* Submodules *)

module Client = struct
  type connection = t

  type request = client_request = {
    meth : string;
    scheme : string option;
    authority : string option;
    path : string;
    headers : (string * string) list;
  }

  type response = client_response = {
    status : int;
    headers : (string * string) list;
    body : Body.Reader.t;
  }

  type error_handler = error -> unit
  type response_handler = Stream.id -> response -> unit
  type trailers_handler = (string * string) list -> unit

  let create ?config ?push_handler ~error_handler () =
    (match push_handler with
    | None -> ()
    | Some _ ->
        invalid_arg
          "Eta_http_h2.Connection.Client.create: server push is not supported");
    let state =
      {
        client_error_handler = error_handler;
        client_streams = Hashtbl.create 64;
      }
    in
    let conn = create_connection ?config (Client state) in
    send_client_preface conn;
    conn

  let header_is_pseudo (name, _) =
    String.length name > 0 && Char.equal name.[0] ':'

  let require_no_pseudo_headers headers =
    match List.find_opt header_is_pseudo headers with
    | None -> ()
    | Some (name, _) ->
        invalid_arg
          ("Eta_http_h2.Connection.Client.request: pseudo-header in headers: "
         ^ name)

  let validate_stream_id t stream_id =
    if stream_id <= 0 || stream_id land 1 = 0 then
      invalid_arg
        "Eta_http_h2.Connection.Client.request: client stream id must be \
         positive odd";
    if stream_id <= t.max_client_stream_id then
      invalid_arg
        "Eta_http_h2.Connection.Client.request: client stream id was already \
         used";
    if stream_id > 0x7fffffff then
      invalid_arg
        "Eta_http_h2.Connection.Client.request: client stream id exhausted"

  let request_headers (request : request) =
    require_no_pseudo_headers request.headers;
    let meth = String.uppercase_ascii request.meth in
    if String.equal meth "CONNECT" then (
      match request.authority with
      | None ->
          invalid_arg
            "Eta_http_h2.Connection.Client.request: CONNECT requires :authority"
      | Some authority ->
          [ (":method", request.meth); (":authority", authority) ]
          @ request.headers)
    else (
      match request.scheme with
      | None ->
          invalid_arg
            "Eta_http_h2.Connection.Client.request: request requires :scheme"
      | Some scheme ->
          let authority =
            match request.authority with
            | None -> []
            | Some authority -> [ (":authority", authority) ]
          in
          [ (":method", request.meth); (":scheme", scheme) ]
          @ authority @ [ (":path", request.path) ] @ request.headers)

  let request t ~stream_id ?(end_stream = false) ?trailers_handler
      (request : request) ~error_handler ~response_handler =
    match t.role with
    | Server _ ->
        invalid_arg
          "Eta_http_h2.Connection.Client.request: server connection used as \
           client"
    | Client c ->
        if not (accepts_new_streams t) then
          invalid_arg
            "Eta_http_h2.Connection.Client.request: connection is not \
             accepting new streams";
        if t.current_client_streams + 1 > t.peer_settings.max_concurrent_streams
        then
          invalid_arg
            "Eta_http_h2.Connection.Client.request: peer max_concurrent_streams \
             exceeded";
        validate_stream_id t stream_id;
        let stream = open_stream t ~id:stream_id in
        let response_body = Stream.request_body stream in
        let writer = Body.Writer.create () in
        t.max_client_stream_id <- stream_id;
        t.current_client_streams <- t.current_client_streams + 1;
        Hashtbl.replace c.client_streams stream_id
          {
            request;
            response_body;
            error_handler;
            response_handler;
            trailers_handler;
            response_started = false;
          };
        let header_block = encode_header_list t (request_headers request) in
        send_header_block t ~stream_id header_block ~end_stream;
        if end_stream then (
            Stream.mark_send_end_stream stream;
            Stream.mark_sent_end_stream stream;
            Body.Writer.close writer)
        else (
          Body.Writer.set_write_fn writer (fun buf ~off ~len ->
              match Stream.queue_data stream buf ~off ~len with
              | Ok () -> wake_schedulable_stream t stream
              | Error Stream.Stream_closed -> ()
              | Error (Protocol_violation message)
              | Error (Flow_control_violation message) ->
                  client_stream_error t stream_id Error_code.Protocol_error
                    message);
          Body.Writer.set_flush_fn writer (fun fn -> Stream.on_drained stream fn);
          Body.Writer.set_close_callback writer (fun () ->
              Stream.mark_send_end_stream stream;
              wake_schedulable_stream t stream));
        wake_writer t;
        writer
end

module Server = struct
  type connection = t

  type request = server_request = {
    stream_id : int;
    meth : string;
    scheme : string;
    authority : string option;
    path : string;
    headers : (string * string) list;
    body : Body.Reader.t;
  }

  type response = server_response = {
    status : int;
    headers : (string * string) list;
    body : [ `Empty | `String of string | `Reader of Body.Reader.t ];
    trailers : (string * string) list Lazy.t;
  }

  type request_handler = reqd -> unit
  type error_handler = error -> unit

  let create ?config ~request_handler ~error_handler () =
    create_connection ?config (Server { request_handler; error_handler })

  module Reqd = struct
    type t = reqd

    let request t = t.request
    let request_body t = t.request.body

    let respond_with_string t response body = respond t response (`String body)

    let respond_with_streaming t response =
      let writer = Body.Writer.create () in
      respond t response (`Streaming writer);
      writer

    let schedule_trailers t trailers =
      t.trailers_opt <- Some (Lazy.from_val trailers);
      Stream.set_trailers t.stream trailers

    let report_exn t exn =
      ignore exn;
      reset_stream t.connection (Stream.id t.stream) Error_code.Internal_error
  end
end

let create = Server.create
