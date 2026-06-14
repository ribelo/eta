(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Server = Eta_http.Server
module Types = Server_types
module H2 = Eta_http.H2

type flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

type stats = Server_stats.H2.snapshot = {
  active_streams : int;
  opened_streams : int;
  completed_streams : int;
  reset_streams : int;
  request_bytes : int;
  response_bytes : int;
  protocol_errors : int;
}

type time = Types.time = {
  now_ms : unit -> int64;
  sleep : Eta.Duration.t -> unit;
  with_timeout : 'a. Eta.Duration.t -> (unit -> 'a) -> 'a;
}

type request_body_read = (bytes option, Server.Error.t) result
type unit_result = (unit, Server.Error.t) result

type response_body =
  | Response_no_body of Server.Response.Body.stream option
  | Response_fixed of bytes list * int
  | Response_stream of Server.Response.Body.stream

type request_header_block = {
  stream_id : int;
  ordinal : int;
  trailers : bool;
  normalize : bool;
  end_stream : bool;
  block : Buffer.t;
}

type ingress_frame_action =
  | Pass_frame
  | Drop_frame
  | Emit_frame of string

type prepared_response = {
  status : int;
  headers : Eta_http.Core.Header.t;
  body : response_body;
}

type write_job = {
  data : Cstruct.t;
  len : int;
}

type response_drain = {
  resolver : unit_result Eio.Promise.u;
  finish_on_complete : bool;
}

type request_body_state =
  | Request_body_open
  | Request_body_draining
  | Request_body_ignored
  | Request_body_peer_closed
  | Request_body_reset

type response_state =
  | Response_idle
  | Response_streaming
  | Response_closed
  | Response_reset

type request_trailers = {
  promise : (Eta_http.Core.Header.t, Server.Error.t) result Eio.Promise.t;
  resolver : (Eta_http.Core.Header.t, Server.Error.t) result Eio.Promise.u;
}

type deferred_close =
  | Close_all
  | Shutdown_send

type command =
  | Ingress of {
      bytes : Bigstringaf.t;
      off : int;
      len : int;
      ack : unit Eio.Promise.u;
    }
  | Ingress_eof
  | Ingress_failed of Server.Error.t
  | Idle_timeout of unit Eio.Promise.u
  | Request_body_read of int * request_body_read Eio.Promise.u
  | Request_body_timeout of int * request_body_read Eio.Promise.u
  | Request_body_drain_timeout of int * unit Eio.Promise.u
  | Request_body_discard of int * bool * (unit, Server.Error.t) result Eio.Promise.u
  | Response_start of int * prepared_response * unit_result Eio.Promise.u
  | Response_chunk of int * bytes * unit_result Eio.Promise.u
  | Response_trailers of int * Eta_http.Core.Header.t * unit_result Eio.Promise.u
  | Response_close of int * unit_result Eio.Promise.u
  | Response_failed of int * Server.Error.t
  | Write_completed of (int, Server.Error.t) result
  | Shutdown of Types.shutdown

type stream_state = {
  stream_id : int;
  reqd : H2.Connection.Server.Reqd.t;
  request_body : H2.Body.Reader.t;
  request_content_length : int option;
  metrics : Server_metrics.t option;
  mutable metrics_finished : bool;
  mutable request_body_bytes : int;
  mutable request_body_state : request_body_state;
  request_trailers : request_trailers;
  mutable request_read_resolver : request_body_read Eio.Promise.u option;
  mutable request_discard_resolver :
    (unit, Server.Error.t) result Eio.Promise.u option;
  mutable request_discard_timeout_token : unit Eio.Promise.u option;
  mutable response_writer : H2.Body.Writer.t option;
  mutable response_write_resolver : unit_result Eio.Promise.u option;
  mutable response_drain : response_drain option;
  mutable response_state : response_state;
}

(* Tracks one in-flight handler for the timeout watchdog: a deadline (ms since
   epoch, plain int to avoid int64 boxing) and the handler fiber's cancellation
   context, which the watchdog cancels if the deadline passes. *)
type handler_watch = {
  hw_deadline : int;
  hw_cancel : Eio.Cancel.t;
}

type t = {
  sw : Eio.Switch.t;
  now_ms : unit -> int64;
  sleep : Eta.Duration.t -> unit;
  with_timeout : 'a. Eta.Duration.t -> (unit -> 'a) -> 'a;
  flow : flow;
  h2 : H2.Connection.t;
  security : Eta_http.H2.Security.t;
  mutable security_preface_remaining : int;
  ingress_buffer : Bigstringaf.t;
  max_ingress_buffer_size : int;
  mutable ingress_off : int;
  mutable ingress_len : int;
  mutable filter_preface_remaining : int;
  mutable filter_pending : string;
  request_header_decoder : Eta_http.Hpack.t;
  request_header_encoder : Eta_http.Hpack.encoder;
  mutable encoder_buffer : Bytes.t;
  mutable normalize_request_headers : bool;
  mutable request_header_block : request_header_block option;
  mutable observed_request_ordinal : int;
  mutable highest_observed_client_stream_id : int;
  mutable highest_processed_stream_id : int;
  mutable graceful_shutdown_last_stream_id : int option;
  mutable graceful_shutdown_goaway_sent : bool;
  mutable graceful_rejected_header_stream : int option;
  stream_ordinals : (int, int) Hashtbl.t;
  stream_ids_by_ordinal : (int, int) Hashtbl.t;
  graceful_rejected_streams : (int, unit) Hashtbl.t;
  pending_request_trailers : (int, Eta_http.Core.Header.t) Hashtbl.t;
  remote_end_streams : (int, unit) Hashtbl.t;
  remote_reset_streams : (int, unit) Hashtbl.t;
  remote_reset_ordinals : (int, unit) Hashtbl.t;
  mutable pending_control_frames : string list;
  commands : command Eio.Stream.t;
  write_jobs : write_job Eio.Stream.t;
  streams : (int, stream_state) Hashtbl.t;
  connection : Types.Connection_info.t;
  config : Types.Config.t;
  runtime_factory : Types.runtime_factory;
  runtime : Eta_http.Server.Error.t Eta.Runtime.t;
  stats : Server_stats.H2.t;
  connection_metrics : Server_metrics.t option;
  closed_signal : unit Eio.Promise.t;
  close_signal : unit Eio.Promise.u;
  mutable handler_sw : Eio.Switch.t option;
  handler_watches : (int, handler_watch) Hashtbl.t;
  mutable idle_timeout_token : unit Eio.Promise.u option;
  mutable graceful_shutdown : bool;
  mutable shutdown_timer_started : bool;
  mutable accepted_request : bool;
  mutable deferred_close : deferred_close option;
  mutable write_pending : bool;
  mutable write_buffer : Cstruct.t;
  mutable emit_buffer : Buffer.t;
  read_owned : Bigstringaf.t;
  mutable closed : bool;
}

let mark_closed t =
  if not t.closed then (
    t.closed <- true;
    ignore (Eio.Promise.try_resolve t.close_signal ()))

let graceful_close_flow_all flow =
  (try Eio.Flow.shutdown flow `All with _ -> ());
  try Eio.Flow.close flow with _ -> ()

let abortive_close_flow flow = try Eio.Flow.close flow with _ -> ()

let stats t =
  Server_stats.H2.snapshot t.stats
    ~active_streams:(Hashtbl.length t.streams)

let request_metrics ~config ~runtime ~connection request =
  if config.Types.Config.server.enable_otel then
    Some
      (Server_metrics.request ~runtime ~connection
         ~emit_url_full:config.server.emit_url_full request)
  else None

let connection_metrics ~config ~runtime ~connection =
  if config.Types.Config.server.enable_otel then
    Some (Server_metrics.connection ~runtime ~connection)
  else None

let emit_connection_metric t f =
  Option.iter f t.connection_metrics

let record_protocol_error t =
  Server_stats.H2.protocol_error t.stats;
  emit_connection_metric t (fun metrics ->
      Server_metrics.protocol_errors metrics 1)

let finish_stream_metrics state =
  if not state.metrics_finished then (
    Option.iter Server_metrics.request_finished state.metrics;
    Option.iter Server_metrics.stream_finished state.metrics;
    state.metrics_finished <- true)

let peer_of_sockaddr = function
  | `Tcp (address, port) ->
      {
        Server.Request.address =
          Some (Format.asprintf "%a" Eio.Net.Ipaddr.pp address);
        port = Some port;
      }
  | `Unix path -> { Server.Request.address = Some path; port = None }

let connection_id =
  let next = Atomic.make 0 in
  fun () ->
    let id = Atomic.fetch_and_add next 1 + 1 in
    "h2c-" ^ string_of_int id

let request_id connection_id ordinal =
  connection_id ^ "/stream-" ^ string_of_int ordinal

let method_to_string method_ = H2.Method.to_string method_

let connection_url_scheme t =
  Server.Validation.connection_scheme ~tls:t.connection.tls

let validate_config = Types.Config.validate

let resolve resolver value = ignore (Eio.Promise.try_resolve resolver value)

let create_request_trailers () =
  let promise, resolver = Eio.Promise.create () in
  { promise; resolver }

let resolve_request_trailers state trailers =
  resolve state.request_trailers.resolver (Ok trailers)

let resolve_request_trailers_empty state =
  resolve_request_trailers state Eta_http.Core.Header.empty

let fail_request_trailers state error =
  resolve state.request_trailers.resolver (Error error)

let request_body_accepts_peer_frame = function
  | Request_body_open | Request_body_draining | Request_body_ignored -> true
  | Request_body_peer_closed | Request_body_reset -> false

let request_body_terminal = function
  | Request_body_peer_closed | Request_body_reset -> true
  | Request_body_open | Request_body_draining | Request_body_ignored -> false

let request_body_available_to_app = function
  | Request_body_open | Request_body_peer_closed -> true
  | Request_body_draining | Request_body_ignored | Request_body_reset -> false

let response_terminal = function
  | Response_closed | Response_reset -> true
  | Response_idle | Response_streaming -> false

let request_body_peer_closed state =
  match state.request_body_state with
  | Request_body_peer_closed | Request_body_reset -> ()
  | Request_body_open | Request_body_draining | Request_body_ignored ->
      state.request_body_state <- Request_body_peer_closed

let request_body_draining state =
  match state.request_body_state with
  | Request_body_open | Request_body_ignored ->
      state.request_body_state <- Request_body_draining
  | Request_body_draining | Request_body_peer_closed | Request_body_reset -> ()

let close_request_body_reader state =
  try
    if not (H2.Body.Reader.is_closed state.request_body) then
      H2.Body.Reader.close state.request_body
  with _ -> ()

let ignore_request_body state =
  (match state.request_body_state with
  | Request_body_peer_closed | Request_body_reset -> ()
  | Request_body_open | Request_body_draining | Request_body_ignored ->
      state.request_body_state <- Request_body_ignored);
  close_request_body_reader state

let reset_request_body state =
  state.request_body_state <- Request_body_reset;
  close_request_body_reader state

let response_streaming state =
  match state.response_state with
  | Response_idle -> state.response_state <- Response_streaming
  | Response_streaming | Response_closed | Response_reset -> ()

let response_closed state =
  match state.response_state with
  | Response_reset -> ()
  | Response_idle | Response_streaming | Response_closed ->
      state.response_state <- Response_closed

let response_reset state = state.response_state <- Response_reset

let enqueue t command =
  if t.closed then false
  else (
    Eio.Stream.add t.commands command;
    true)

let request_body_closed_error t ordinal =
  ignore ordinal;
  Server.Error.make ~protocol:t.connection.protocol ~method_:"*" ~target:"*"
    (Connection_closed { during = Request_body })

let connection_closed_error t during =
  Server.Error.make ~protocol:t.connection.protocol ~method_:"*" ~target:"*"
    (Connection_closed { during })

let request_timeout_error t timeout =
  Server.Error.make ~protocol:t.connection.protocol ~method_:"*" ~target:"*"
    (Request_timeout
       { timeout_ms = Option.map Eta.Duration.to_ms timeout })

let handler_timeout_error t request timeout =
  Server.Error.make ~protocol:t.connection.protocol
    ~method_:request.Server.Request.method_ ~target:request.target
    (Handler_timeout
       { timeout_ms = Option.map Eta.Duration.to_ms timeout })

let request_body_too_large_error t ~limit ~length =
  Server.Error.make ~protocol:t.connection.protocol ~method_:"*" ~target:"*"
    (Request_body_too_large { limit; length })

let request_body_length_mismatch_error t ~expected ~actual =
  Server.Error.make ~protocol:t.connection.protocol ~method_:"*" ~target:"*"
    (Bad_request
       {
         message =
           Printf.sprintf
             "HTTP/2 content-length mismatch: expected %d bytes, got %d"
             expected actual;
       })

let shutdown_error t = connection_closed_error t Shutdown

let connection_read_error t exn =
  Server.Error.make ~protocol:t.connection.protocol ~method_:"*" ~target:"*"
    (Protocol_error
       {
         kind = "connection_read_failed";
         message = Printexc.to_string exn;
       })

let response_write_error t ?(message = "response stream is not writable") () =
  Server.Error.make ~protocol:t.connection.protocol ~method_:"*" ~target:"*"
    (Response_write_failed { message })

let connection_write_error t exn =
  response_write_error t
    ~message:("connection write failed: " ^ Printexc.to_string exn)
    ()

let response_write_timeout_error t =
  response_write_error t ~message:"response write timed out" ()

let response_body_timeout_error t request timeout =
  Server.Error.make ~protocol:t.connection.protocol
    ~method_:request.Server.Request.method_ ~target:request.target
    (Response_body_timeout
       { timeout_ms = Option.map Eta.Duration.to_ms timeout })

let security_error t kind =
  let http_error =
    Eta_http.Error.make ~protocol:Eta_http.Error.H2 ~method_:"*" ~uri:"*" kind
  in
  match kind with
  | Eta_http.Error.Header_invalid { reason } ->
      Server.Error.make ~protocol:t.connection.protocol ~method_:"*" ~target:"*"
        (Header_invalid { reason })
  | Eta_http.Error.Connection_closed _ -> connection_closed_error t Connection
  | _ ->
      Server.Error.make ~protocol:t.connection.protocol ~method_:"*" ~target:"*"
        (Protocol_error
           {
             kind = Eta_http.Error.kind_name kind;
             message = Eta_http.Error.to_string http_error;
           })

let h2_client_connection_preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
let h2_client_connection_preface_length =
  String.length h2_client_connection_preface

let observe_ingress_security t bytes ~off ~len =
  let off, len =
    if t.security_preface_remaining = 0 then (off, len)
    else
      let skipped = min t.security_preface_remaining len in
      t.security_preface_remaining <- t.security_preface_remaining - skipped;
      (off + skipped, len - skipped)
  in
  if len = 0 then Eta_http.H2.Security.Pass
  else
    Eta_http.H2.Security.observe_result t.security bytes ~off ~len
      ~now_ms:(t.now_ms ())

let frame_header_size = 9

let frame_length s off =
  (Char.code s.[off] lsl 16)
  lor (Char.code s.[off + 1] lsl 8)
  lor Char.code s.[off + 2]

let frame_type s off = Char.code s.[off + 3]
let frame_flags s off = Char.code s.[off + 4]

let frame_stream_id s off =
  ((Char.code s.[off + 5] land 0x7f) lsl 24)
  lor (Char.code s.[off + 6] lsl 16)
  lor (Char.code s.[off + 7] lsl 8)
  lor Char.code s.[off + 8]

let client_request_stream_id stream_id = stream_id > 0 && stream_id land 1 = 1

let note_processed_stream_id t stream_id =
  if stream_id > t.highest_processed_stream_id then
    t.highest_processed_stream_id <- stream_id

let graceful_shutdown_cutoff t =
  Option.value t.graceful_shutdown_last_stream_id
    ~default:t.highest_processed_stream_id

let flag_end_stream = 0x1
let flag_end_headers = 0x4
let flag_padded = 0x8
let flag_priority = 0x20

let h2_no_error = 0
let h2_protocol_error = 1
let h2_flow_control_error = 3
let h2_stream_closed = 5
let h2_frame_size_error = 6
let h2_compression_error = 9
let h2_enhance_your_calm = 11

let configured_max_frame_size t =
  t.config.Types.Config.h2_config.Eta_http.H2.Config.read_buffer_size

let h2_filter_protocol_violation ~kind ~message =
  Eta_http.Error.Connection_protocol_violation { kind; message }

let invalid_preface_error =
  h2_filter_protocol_violation ~kind:"h2_preface"
    ~message:"invalid HTTP/2 client connection preface"

let stream_closed_frame_error stream_id =
  h2_filter_protocol_violation ~kind:"stream_closed"
    ~message:
      (Printf.sprintf
         "HTTP/2 request body frame received on closed stream %d" stream_id)

let frame_size_error t length =
  h2_filter_protocol_violation ~kind:"h2_frame_size"
    ~message:
      (Printf.sprintf
         "HTTP/2 frame payload length %d exceeds configured max frame size %d"
         length (configured_max_frame_size t))

let filter_pending_error t needed =
  h2_filter_protocol_violation ~kind:"h2_filter_buffer_exhausted"
    ~message:
      (Printf.sprintf
         "h2 ingress filter needs %d bytes, limit is %d bytes" needed
         (frame_header_size + configured_max_frame_size t))

let request_trailer_error message =
  h2_filter_protocol_violation ~kind:"h2_request_trailers" ~message

let request_header_error message =
  h2_filter_protocol_violation ~kind:"h2_request_headers" ~message

let connection_filter_error ?(code = 1) kind =
  Eta_http.H2.Security.Connection_error { code; kind }

let stream_filter_error ?(code = 1) ~stream_id kind =
  Eta_http.H2.Security.Stream_error { stream_id; code; kind }

let code s i = Char.code (String.unsafe_get s i)

let note_headers_frame t stream_id =
  if
    client_request_stream_id stream_id
    && not (Hashtbl.mem t.stream_ordinals stream_id)
  then (
    if stream_id > t.highest_observed_client_stream_id then
      t.highest_observed_client_stream_id <- stream_id;
    t.observed_request_ordinal <- t.observed_request_ordinal + 1;
    Hashtbl.add t.stream_ordinals stream_id t.observed_request_ordinal;
    Hashtbl.add t.stream_ids_by_ordinal t.observed_request_ordinal stream_id)

let stream_state_by_stream_id t stream_id =
  match Hashtbl.find_opt t.stream_ordinals stream_id with
  | None -> None
  | Some ordinal -> Hashtbl.find_opt t.streams ordinal

let mark_remote_end_stream t stream_id =
  if client_request_stream_id stream_id then (
    Hashtbl.replace t.remote_end_streams stream_id ();
    match stream_state_by_stream_id t stream_id with
    | None -> ()
    | Some state -> request_body_peer_closed state)

let request_body_frame_type = function
  | 0x0 | 0x1 | 0x9 -> true
  | _ -> false

let request_body_frame_on_closed_stream t frame_type stream_id =
  client_request_stream_id stream_id
  && request_body_frame_type frame_type
  &&
  match stream_state_by_stream_id t stream_id with
  | Some state -> not (request_body_accepts_peer_frame state.request_body_state)
  | None -> Hashtbl.mem t.remote_end_streams stream_id

let request_header_fragment flags payload =
  let len = String.length payload in
  let pos = ref 0 in
  let pad_len =
    if flags land flag_padded = 0 then 0
    else if len = 0 then -1
    else (
      pos := 1;
      code payload 0)
  in
  if pad_len < 0 then
    Error
      (connection_filter_error
         (request_trailer_error "PADDED HEADERS frame is missing Pad Length"))
  else (
    if flags land flag_priority <> 0 then pos := !pos + 5;
    if !pos > len || !pos + pad_len > len then
      Error
        (connection_filter_error
           (request_trailer_error
              "HEADERS padding/priority fields exceed payload"))
    else Ok (String.sub payload !pos (len - !pos - pad_len)))

let decode_request_header_block t block =
  let result = Eta_http.Hpack.decode_headers_string t.request_header_decoder block in
  result
  |> Result.map_error (fun _ -> request_trailer_error "HPACK decoding error")

let encode_request_header_block t (headers : Eta_http.Hpack.header list) =
  let buf = t.encoder_buffer in
  let pos_ref = ref 0 in
  List.iter
    (Eta_http.Hpack.encode_single_header t.request_header_encoder buf pos_ref)
    headers;
  Bytes.sub_string buf 0 !pos_ref

let emit_header_block t ~stream_id ~end_stream block =
  let max_payload = 16 * 1024 in
  let total = String.length block in
  let output = t.emit_buffer in
  Buffer.clear output;
  let rec loop off first =
    let remaining = total - off in
    if remaining <= max_payload then (
      let flags =
        flag_end_headers
        lor (if first && end_stream then flag_end_stream else 0)
      in
      let frame_type =
        if first then Eta_http.H2.Frame.Headers
        else Eta_http.H2.Frame.Continuation
      in
      Buffer.add_string output
        (Eta_http.H2.Frame.header ~length:remaining ~frame_type ~flags
           ~stream_id);
      Buffer.add_substring output block off remaining)
    else (
      let flags = if first && end_stream then flag_end_stream else 0 in
      let frame_type =
        if first then Eta_http.H2.Frame.Headers
        else Eta_http.H2.Frame.Continuation
      in
      Buffer.add_string output
        (Eta_http.H2.Frame.header ~length:max_payload ~frame_type ~flags
           ~stream_id);
      Buffer.add_substring output block off max_payload;
      loop (off + max_payload) false)
  in
  loop 0 true;
  Buffer.contents output

let end_stream_data_frame stream_id =
  Eta_http.H2.Frame.header ~length:0 ~frame_type:Data ~flags:flag_end_stream
    ~stream_id

let rst_stream_frame ~stream_id error_code =
  Eta_http.H2.Frame.header ~length:4 ~frame_type:Rst_stream ~flags:0
    ~stream_id
  ^ Eta_http.H2.Frame.uint32 error_code

let validate_request_trailers t trailers =
  let limits = t.config.server.limits in
  match Server.Validation.validate_h2_request_trailers ~limits trailers with
  | Error message -> Error (connection_filter_error (request_trailer_error message))
  | Ok () -> (
      match Eta_http.Core.Header.of_list trailers with
      | Ok trailers -> Ok trailers
      | Error kind ->
          Error
            (connection_filter_error
               (request_trailer_error
                  ("invalid request trailer header: "
                 ^ Eta_http.Error.kind_name kind))))

let validate_decoded_request_header_names block headers =
  let has_empty_name = List.exists (fun (name, _) -> String.equal name "") headers in
  if not has_empty_name then Ok ()
  else if block.trailers then
    Error
      (connection_filter_error
         (request_trailer_error "empty HTTP/2 request trailer header name"))
  else
    Error
      (connection_filter_error
         (request_header_error "empty HTTP/2 request header name"))

let decoded_header_block_bytes headers =
  List.fold_left
    (fun total (name, value) -> total + String.length name + String.length value + 32)
    0 headers

let validate_decoded_request_header_limits t headers =
  let limits = t.config.server.limits in
  let count = List.length headers in
  if count > limits.max_request_headers then
    Error
      (connection_filter_error ~code:h2_compression_error
         (request_header_error
            (Printf.sprintf "request header count exceeds %d"
               limits.max_request_headers)))
  else
    let bytes = decoded_header_block_bytes headers in
    if bytes > limits.max_request_header_bytes then
      Error
        (connection_filter_error ~code:h2_compression_error
           (request_header_error
              (Printf.sprintf "request header section exceeds %d bytes"
                 limits.max_request_header_bytes)))
    else Ok ()

let store_request_trailers t ordinal trailers =
  match Hashtbl.find_opt t.streams ordinal with
  | Some state -> resolve_request_trailers state trailers
  | None -> Hashtbl.replace t.pending_request_trailers ordinal trailers

let complete_request_header_block t block =
  if block.trailers && not block.end_stream then (
    t.request_header_block <- None;
    Error
      (connection_filter_error
         (request_trailer_error
            "request trailer HEADERS frame is missing END_STREAM")))
  else
  match decode_request_header_block t (Buffer.contents block.block) with
  | Error error -> Error (connection_filter_error error)
  | Ok headers ->
      (match validate_decoded_request_header_names block headers with
      | Error _ as error -> error
      | Ok () ->
          (match
             if block.trailers then Ok ()
             else validate_decoded_request_header_limits t headers
           with
          | Error _ as error -> error
          | Ok () ->
          t.request_header_block <- None;
          if block.end_stream then
            mark_remote_end_stream t block.stream_id;
          if (not block.trailers) && not block.normalize then Ok Pass_frame
          else if not block.trailers then (
            Ok
              (Emit_frame
                 (emit_header_block t ~stream_id:block.stream_id
                    ~end_stream:block.end_stream
                    (encode_request_header_block t
                       (List.map
                          (fun (name, value) ->
                            { Eta_http.Hpack.name; value; sensitive = false })
                          headers)))))
          else
            (match validate_request_trailers t headers with
            | Error _ as error -> error
            | Ok trailers ->
                store_request_trailers t block.ordinal trailers;
                t.normalize_request_headers <- true;
                Ok (Emit_frame (end_stream_data_frame block.stream_id)))))

let observe_request_headers_frame t frames off length flags stream_id =
  if not (client_request_stream_id stream_id) then Ok Pass_frame
  else
    let first = not (Hashtbl.mem t.stream_ordinals stream_id) in
    if first then note_headers_frame t stream_id;
    if not first then t.normalize_request_headers <- true;
    let ordinal = Hashtbl.find t.stream_ordinals stream_id in
    let payload =
      String.sub frames (off + frame_header_size) length
    in
    match request_header_fragment flags payload with
    | Error _ as error -> error
    | Ok fragment ->
        let block =
          {
            stream_id;
            ordinal;
            trailers = not first;
            normalize = (not first) || t.normalize_request_headers;
            end_stream = flags land flag_end_stream <> 0;
            block = Buffer.create (String.length fragment);
          }
        in
        Buffer.add_string block.block fragment;
        if flags land flag_end_headers <> 0 then (
          complete_request_header_block t block)
        else (
          t.request_header_block <- Some block;
          if block.normalize then Ok Drop_frame else Ok Pass_frame)

let observe_request_continuation_frame t frames off length flags stream_id =
  match t.request_header_block with
  | None -> Ok Pass_frame
  | Some block when block.stream_id <> stream_id -> Ok Pass_frame
  | Some block ->
      Buffer.add_substring block.block frames (off + frame_header_size) length;
      if flags land flag_end_headers <> 0 then complete_request_header_block t block
      else if block.normalize then Ok Drop_frame
      else Ok Pass_frame

let h2_refused_stream = 7

let enqueue_control_frame t frame =
  t.pending_control_frames <- frame :: t.pending_control_frames

let reject_graceful_shutdown_stream t stream_id flags =
  Hashtbl.replace t.graceful_rejected_streams stream_id ();
  if flags land flag_end_headers = 0 then
    t.graceful_rejected_header_stream <- Some stream_id;
  enqueue_control_frame t (rst_stream_frame ~stream_id h2_refused_stream);
  Drop_frame

let should_reject_graceful_shutdown_stream t stream_id =
  t.graceful_shutdown && client_request_stream_id stream_id
  && stream_id > graceful_shutdown_cutoff t
  && not (Hashtbl.mem t.stream_ordinals stream_id)

let observe_graceful_rejected_frame t frame_type flags stream_id =
  if Option.equal Int.equal t.graceful_rejected_header_stream (Some stream_id)
     && frame_type = 0x9
  then (
    if flags land flag_end_headers <> 0 then
      t.graceful_rejected_header_stream <- None;
    Some Drop_frame)
  else if Hashtbl.mem t.graceful_rejected_streams stream_id then (
    if frame_type = 0x3 then Hashtbl.remove t.graceful_rejected_streams stream_id;
    Some Drop_frame)
  else if frame_type = 0x1 && should_reject_graceful_shutdown_stream t stream_id
  then Some (reject_graceful_shutdown_stream t stream_id flags)
  else None

let note_remote_reset_frame t stream_id =
  match Hashtbl.find_opt t.stream_ordinals stream_id with
  | None -> ()
  | Some ordinal ->
      Hashtbl.replace t.remote_reset_streams stream_id ();
      Hashtbl.replace t.remote_reset_ordinals ordinal ()

let filter_ingress t bytes ~off ~len =
  let raw = Bigstringaf.substring bytes ~off ~len in
  let raw_len = String.length raw in
  let output = Buffer.create raw_len in
  let frame_off =
    if t.filter_preface_remaining = 0 then Ok 0
    else
      let consumed =
        h2_client_connection_preface_length - t.filter_preface_remaining
      in
      let prefix_len = min t.filter_preface_remaining raw_len in
      let rec validate index =
        if index = prefix_len then Ok ()
        else
          let expected =
            String.unsafe_get h2_client_connection_preface (consumed + index)
          in
          if Char.equal (String.unsafe_get raw index) expected then
            validate (index + 1)
          else Error invalid_preface_error
      in
      match validate 0 with
      | Error kind -> Error (connection_filter_error kind)
      | Ok () ->
          Buffer.add_substring output raw 0 prefix_len;
          t.filter_preface_remaining <- t.filter_preface_remaining - prefix_len;
          Ok prefix_len
  in
  match frame_off with
  | Error kind -> Error kind
  | Ok frame_off ->
      let frames =
        let frame_bytes = String.sub raw frame_off (raw_len - frame_off) in
        if String.equal t.filter_pending "" then frame_bytes
        else t.filter_pending ^ frame_bytes
      in
      t.filter_pending <- "";
      let frames_len = String.length frames in
      let set_pending off =
        let pending_len = frames_len - off in
        let pending_limit = frame_header_size + configured_max_frame_size t in
        if pending_len > pending_limit then
          Error (connection_filter_error (filter_pending_error t pending_len))
        else (
          t.filter_pending <- String.sub frames off pending_len;
          Ok ())
      in
      let rec loop off =
        if off + frame_header_size > frames_len then set_pending off
        else
          let length = frame_length frames off in
          let total = frame_header_size + length in
          if length > configured_max_frame_size t then
            Error (connection_filter_error ~code:6 (frame_size_error t length))
          else if off + total > frames_len then set_pending off
          else (
            let ty = frame_type frames off in
            let flags = frame_flags frames off in
            let stream_id = frame_stream_id frames off in
            if request_body_frame_on_closed_stream t ty stream_id then
              Error
                (stream_filter_error ~code:5 ~stream_id
                   (stream_closed_frame_error stream_id))
            else if ty = 0x0 && Hashtbl.mem t.remote_reset_streams stream_id then
              Error
                (stream_filter_error ~code:5 ~stream_id
                   (stream_closed_frame_error stream_id))
            else (
              let observed =
                match observe_graceful_rejected_frame t ty flags stream_id with
                | Some action -> Ok action
                | None ->
                    if ty = 0x1 then
                      observe_request_headers_frame t frames off length flags
                        stream_id
                    else if ty = 0x9 then
                      observe_request_continuation_frame t frames off length
                        flags stream_id
                    else Ok Pass_frame
              in
              match observed with
              | Error _ as error -> error
              | Ok action ->
                  if ty = 0x3 then note_remote_reset_frame t stream_id;
                  (match action with
                  | Pass_frame -> Buffer.add_substring output frames off total
                  | Drop_frame -> ()
                  | Emit_frame bytes -> Buffer.add_string output bytes);
                  if ty = 0x0 && flags land flag_end_stream <> 0 then
                    mark_remote_end_stream t stream_id;
                  loop (off + total)))
      in
      match loop 0 with
      | Error kind -> Error kind
      | Ok () ->
          let filtered = Buffer.contents output in
          let filtered_len = String.length filtered in
          if filtered_len = 0 then Ok None
          else
            Ok
              (Some
                 ( Bigstringaf.of_string ~off:0 ~len:filtered_len filtered,
                   filtered_len ))

let response_failure_of_cause t cause =
  let message = Format.asprintf "%a" (Eta.Cause.pp Server.Error.pp) cause in
  response_write_error t ~message ()

let body_of_stream t ordinal =
  let read () =
    Eta.Effect.sync (fun () ->
        if t.closed then Error (connection_closed_error t Request_body)
        else
          let promise, resolver = Eio.Promise.create () in
          if enqueue t (Request_body_read (ordinal, resolver)) then
            Eio.Promise.await promise
          else Error (connection_closed_error t Request_body))
    |> Eta.Effect.bind (function
         | Ok chunk -> Eta.Effect.pure chunk
         | Error error -> Eta.Effect.fail error)
  in
  let discard ~drain =
    Eta.Effect.sync (fun () ->
        if t.closed then Error (connection_closed_error t Request_body)
        else
          let promise, resolver = Eio.Promise.create () in
          if enqueue t (Request_body_discard (ordinal, drain, resolver)) then
            Eio.Promise.await promise
          else Error (connection_closed_error t Request_body))
    |> Eta.Effect.bind (function
         | Ok () -> Eta.Effect.unit
         | Error error -> Eta.Effect.fail error)
  in
  Server.Body.of_reader ~discard read

let request_of_reqd ~connection ~ordinal ~stream_id ~body ~trailers reqd =
  let request = H2.Connection.Server.Reqd.request reqd in
  let path, query = Server.Request.split_target request.path in
  {
    Server.Request.id = lazy (request_id connection.Types.Connection_info.id ordinal);
    version = Eta_http.Core.Version.H2;
    scheme = request.scheme;
    authority = request.authority;
    method_ = method_to_string request.meth;
    target = request.path;
    path;
    query;
    headers = Eta_http.Core.Header.unsafe_of_list request.headers;
    body;
    trailers =
      (fun () ->
        Eta.Effect.sync (fun () -> Eio.Promise.await trailers.promise)
        |> Eta.Effect.bind (function
             | Ok trailers -> Eta.Effect.pure trailers
             | Error error -> Eta.Effect.fail error));
    peer = connection.peer;
    tls = connection.tls;
    alpn_protocol = connection.alpn_protocol;
    stream_id = Some stream_id;
    connection_id = connection.id;
  }

let validate_request_metadata t (request : Server.Request.t) =
  match
    Server.Validation.validate_h2_request_headers
      ~limits:t.config.server.limits request.headers
  with
  | Error message ->
      Error
        (Server.Error.make ~protocol:t.connection.protocol
           ~method_:request.method_ ~target:request.target
           (Bad_request { message }))
  | Ok () -> (
      match
        Server.Validation.validate_h2_request
          ~connection_scheme:(connection_url_scheme t) ~method_:request.method_
          ~scheme:request.scheme ~target:request.target
          ~authority:request.authority
      with
      | Ok () -> Ok ()
      | Error message ->
          Error
            (Server.Error.make ~protocol:t.connection.protocol
               ~method_:request.method_ ~target:request.target
               (Bad_request { message })))

(* Normalize header names, sharing structure when nothing changes. HTTP/2
   response header names are already lowercase in the common case, so
   normalize_name returns the same string (no alloc) and this returns the
   original list reference — zero allocation per response. Only when a name
   actually needs lowercasing/trimming do we allocate the changed suffix. *)
let rec normalize_header_names lst =
  match lst with
  | [] -> []
  | ((name, value) as hd) :: tl ->
      let tl' = normalize_header_names tl in
      let n = Eta_http.Core.Header.normalize_name name in
      if n == name && tl' == tl then lst else (n, value) :: tl'

let h2_response response =
  {
    H2.Connection.Server.status = response.status;
    headers = normalize_header_names (Eta_http.Core.Header.to_list response.headers);
    body =
      (match response.body with
      | Response_no_body _ -> `Empty
      (* Single-chunk fast path: the chunk is a freshly produced, unaliased
         response body, so reinterpret it as a string in place. Avoids a
         redundant full-body copy (Bytes.concat allocates a fresh buffer even
         for one element) on every fixed response — the hot body-endpoint path. *)
      | Response_fixed ([ chunk ], _) -> `String (Bytes.unsafe_to_string chunk)
      | Response_fixed (chunks, _) ->
          `String (Bytes.unsafe_to_string (Bytes.concat Bytes.empty chunks))
      | Response_stream _ -> `Reader (H2.Body.Reader.create ()));
    trailers = Lazy.from_val [];
  }

let validate_response_headers t response =
  match
    Server.Validation.validate_h2_response_headers
      ~limits:t.config.server.limits
      (Server.Response.headers response)
  with
  | Ok () -> Ok ()
  | Error message -> Error (response_write_error t ~message ())

let validate_final_response_status t status =
  if status = 101 then
    Error
      (response_write_error t
         ~message:"HTTP/2 final response status 101 is forbidden" ())
  else if Eta_http.Core.Status.is_informational status then
    Error
      (response_write_error t
         ~message:"HTTP/2 informational status cannot be a final response" ())
  else Ok ()

let fixed_body_length t chunks =
  List.fold_left
    (fun acc chunk ->
      match acc with
      | Error _ as error -> error
      | Ok total ->
          let length = Bytes.length chunk in
          if total > max_int - length then
            Error
              (response_write_error t
                 ~message:"response body length overflows int" ())
          else Ok (total + length))
    (Ok 0) chunks

let bodyless_response ~request_method status =
  (match Eta_http.Core.Method.of_string request_method with
  | `HEAD -> true
  | _ -> false)
  || Eta_http.Core.Status.forbids_response_body status

let strict_no_body_status = Eta_http.Core.Status.forbids_response_body

let add_content_length_header length headers =
  Eta_http.Core.Header.unsafe_add "content-length" (string_of_int length) headers

let prepare_h2_response t request response =
  match validate_response_headers t response with
  | Error _ as error -> error
  | Ok () -> (
      let status = Server.Response.status response in
      match validate_final_response_status t status with
      | Error _ as error -> error
      | Ok () -> (
          let headers = Server.Response.headers response in
          match Eta_http.Core.Header.get "content-length" headers with
          | Some _ ->
              Error
                (response_write_error t
                   ~message:"caller supplied HTTP/2 response Content-Length" ())
          | None -> (
              let body = Server.Response.body response in
              let bodyless =
                bodyless_response ~request_method:request.Server.Request.method_
                  status
              in
              let strict_no_body = strict_no_body_status status in
              match (bodyless, strict_no_body, body) with
              | true, true, Server.Response.Body.Stream stream ->
                  Ok
                    {
                      status;
                      headers;
                      body = Response_no_body (Some stream);
                    }
              | true, true, (Empty | Fixed _) ->
                  Ok { status; headers; body = Response_no_body None }
              | true, false, Empty ->
                  Ok
                    {
                      status;
                      headers = add_content_length_header 0 headers;
                      body = Response_no_body None;
                    }
              | true, false, Fixed chunks -> (
                  match fixed_body_length t chunks with
                  | Error _ as error -> error
                  | Ok length ->
                      Ok
                        {
                          status;
                          headers = add_content_length_header length headers;
                          body = Response_no_body None;
                        })
              | true, false, Stream ({ length; _ } as stream) ->
                  Ok
                    {
                      status;
                      headers =
                        (match length with
                        | None -> headers
                        | Some length ->
                            add_content_length_header length headers);
                      body = Response_no_body (Some stream);
                    }
              | false, _, Empty ->
                  Ok
                    {
                      status;
                      headers = add_content_length_header 0 headers;
                      body = Response_no_body None;
                    }
              | false, _, Fixed chunks -> (
                  match fixed_body_length t chunks with
                  | Error _ as error -> error
                  | Ok length ->
                      Ok
                        {
                          status;
                          headers = add_content_length_header length headers;
                          body = Response_fixed (chunks, length);
                        })
              | false, _, Stream ({ length = Some length; _ } as stream) ->
                  Ok
                    {
                      status;
                      headers = add_content_length_header length headers;
                      body = Response_stream stream;
                    }
              | false, _, Stream stream ->
                  Ok { status; headers; body = Response_stream stream })))

let max_h2_data_chunk = 16 * 1024

let write_fixed_chunk writer chunk =
  let len = Bytes.length chunk in
  let rec loop off =
    if off < len then (
      let chunk_len = min max_h2_data_chunk (len - off) in
      match
        H2.Body.Writer.write_string writer (Bytes.sub_string chunk off chunk_len)
      with
      | Ok () -> loop (off + chunk_len)
      | Error _ -> Error "response write failed")
    else Ok ()
  in
  loop 0

let fixed_response_stream chunks length =
  let chunks = ref chunks in
  let current = ref None in
  let offset = ref 0 in
  let rec read () =
    match !current with
    | Some chunk when !offset < Bytes.length chunk ->
        let len = min max_h2_data_chunk (Bytes.length chunk - !offset) in
        let out = Bytes.sub chunk !offset len in
        offset := !offset + len;
        Eta.Effect.pure (Some out)
    | _ -> (
        match !chunks with
        | [] -> Eta.Effect.pure None
        | chunk :: rest ->
            chunks := rest;
            current := Some chunk;
            offset := 0;
            read ())
  in
  {
    Server.Response.Body.length = Some length;
    read;
    release = (fun () -> Eta.Effect.unit);
  }

let find_failure cause =
  let rec loop = function
    | Eta.Cause.Fail error -> Some error
    | Die _ | Interrupt _ | Finalizer _ -> None
    | Sequential causes | Concurrent causes -> List.find_map loop causes
    | Suppressed { primary; _ } -> loop primary
  in
  loop cause

let fallback_error_response t request cause =
  let message = Format.asprintf "%a" (Eta.Cause.pp Server.Error.pp) cause in
  let error =
    match find_failure cause with
    | Some error -> error
    | None ->
        Server.Error.make ~protocol:t.connection.protocol
          ~method_:request.Server.Request.method_ ~target:request.target
          (Handler_failed { message })
  in
  Server.Handler.default_error_response error

let respond_fixed reqd response =
  match response.body with
  | Response_no_body _ ->
      H2.Connection.Server.Reqd.respond_with_string reqd (h2_response response) ""
  | Response_fixed (chunks, _) ->
      H2.Connection.Server.Reqd.respond_with_string reqd (h2_response response)
        (Bytes.unsafe_to_string (Bytes.concat Bytes.empty chunks))
  | Response_stream _ ->
      invalid_arg
        "Eta_http_eio.H2.Server_connection.respond_fixed: streaming body"

let copy_write_job t iovecs =
  let len = H2.IOVec.lengthv iovecs in
  (* Reuse a per-connection write buffer instead of allocating Bytes.create +
     Cstruct.of_bytes (a fresh Bigarray) per write job. Safe because the
     write_pending guard keeps at most one write job in flight: the previous
     job's Flow.write has fully completed (Write_completed clears write_pending)
     before the next copy_write_job runs, so the shared buffer is never aliased
     by an in-progress write. Blit the Bigstringaf iovecs straight into the
     Cstruct buffer (bigarray -> bigarray, no Bytes intermediate). *)
  if len > Cstruct.length t.write_buffer then
    t.write_buffer <- Cstruct.create len;
  let dst_off = ref 0 in
  List.iter
    (fun ({ H2.IOVec.buffer; off; len } : Bigstringaf.t H2.IOVec.t) ->
      let src = Cstruct.of_bigarray ~off ~len buffer in
      Cstruct.blit src 0 t.write_buffer !dst_off len;
      dst_off := !dst_off + len)
    iovecs;
  let data = Cstruct.sub t.write_buffer 0 len in
  { data; len }

let schedule_write_iovecs t iovecs =
  let len = H2.IOVec.lengthv iovecs in
  if len = 0 then (
    H2.Connection.report_write_result t.h2 (`Ok 0);
    true)
  else if t.write_pending then false
  else (
    t.write_pending <- true;
    Eio.Stream.add t.write_jobs (copy_write_job t iovecs);
    false)

let h2_write_batch_budget = 32

let rec drain_writes ?(budget = h2_write_batch_budget) t =
  if (not t.closed) && not t.write_pending then
    match H2.Connection.next_write_operation t.h2 with
    | H2.Connection.Write iovecs ->
        if schedule_write_iovecs t iovecs then
          if budget <= 1 then (
            Eio.Fiber.yield ();
            ())
          else drain_writes ~budget:(budget - 1) t
    | Yield -> ()
    | Close _ ->
        H2.Connection.report_write_result t.h2 `Closed;
        mark_closed t;
        (try Eio.Flow.shutdown t.flow `Send with _ -> ())

let h2_read_buffer_size config =
  config.Types.Config.h2_config.Eta_http.H2.Config.read_buffer_size

let max_ingress_buffer_size config =
  config.Types.Config.read_buffer_size + h2_read_buffer_size config
  + Eta_http.H2.Frame.header_size

let stream_table_initial_capacity (h2_config : Eta_http.H2.Config.t) =
  min h2_config.Eta_http.H2.Config.max_concurrent_streams 256

let limited_h2_config (config : Types.Config.t) =
  let limits = config.server.limits in
  let h2_config = config.h2_config in
  let cap limit = function
    | None -> Some limit
    | Some configured -> Some (min configured limit)
  in
  {
    h2_config with
    Eta_http.H2.Config.max_header_count =
      min limits.max_request_headers h2_config.max_header_count;
    max_header_list_size =
      cap limits.max_request_header_bytes h2_config.max_header_list_size;
  }

let compact_ingress t =
  if t.ingress_off > 0 && t.ingress_len > 0 then (
    Bigstringaf.blit t.ingress_buffer ~src_off:t.ingress_off t.ingress_buffer
      ~dst_off:0 ~len:t.ingress_len;
    t.ingress_off <- 0)
  else if t.ingress_len = 0 then t.ingress_off <- 0

let ingress_buffer_full_error t needed =
  Server.Error.make ~protocol:t.connection.protocol ~method_:"*" ~target:"*"
    (Protocol_error
       {
         kind = "h2_ingress_buffer_exhausted";
         message =
           Printf.sprintf
             "h2 ingress buffer needs %d bytes, limit is %d bytes" needed
             t.max_ingress_buffer_size;
       })

let append_ingress t bytes ~off ~len =
  compact_ingress t;
  let needed = t.ingress_len + len in
  if needed > t.max_ingress_buffer_size then
    Error (ingress_buffer_full_error t needed)
  else (
    Bigstringaf.blit bytes ~src_off:off t.ingress_buffer ~dst_off:t.ingress_len
      ~len;
    t.ingress_len <- needed;
    Ok ())

let feed_ingress t =
  let rec loop () =
    if t.ingress_len > 0 then (
      let consumed =
        H2.Connection.read t.h2 t.ingress_buffer ~off:t.ingress_off
          ~len:t.ingress_len
      in
      if consumed < 0 || consumed > t.ingress_len then
        invalid_arg
          "Eta_http_eio.H2.Server_connection.feed_ingress: invalid h2 consumed \
           count"
      else if consumed > 0 then (
        t.ingress_off <- t.ingress_off + consumed;
        t.ingress_len <- t.ingress_len - consumed;
        if t.ingress_len = 0 then t.ingress_off <- 0;
        loop ()))
  in
  loop ()

let read_eof t =
  let consumed =
    H2.Connection.read_eof t.h2 t.ingress_buffer ~off:t.ingress_off
      ~len:t.ingress_len
  in
  t.ingress_off <- t.ingress_off + consumed;
  t.ingress_len <- max 0 (t.ingress_len - consumed);
  if t.ingress_len = 0 then t.ingress_off <- 0

let fail_pending_request_read state error =
  Option.iter
    (fun resolver -> resolve resolver (Error error))
    state.request_read_resolver;
  state.request_read_resolver <- None

let clear_request_discard state =
  state.request_discard_resolver <- None;
  state.request_discard_timeout_token <- None

let fail_pending_request_discard state error =
  Option.iter
    (fun resolver -> resolve resolver (Error error))
    state.request_discard_resolver;
  clear_request_discard state

let fail_pending_response_write state error =
  Option.iter
    (fun resolver -> resolve resolver (Error error))
    state.response_write_resolver;
  state.response_write_resolver <- None;
  Option.iter
    (fun ({ resolver; _ } : response_drain) -> resolve resolver (Error error))
    state.response_drain;
  state.response_drain <- None

let close_request_body state =
  clear_request_discard state;
  reset_request_body state

let forget_stream t ordinal state =
  state.response_writer <- None;
  Eta_http.H2.Security.complete_stream t.security state.stream_id;
  Hashtbl.remove t.stream_ordinals state.stream_id;
  Hashtbl.remove t.stream_ids_by_ordinal ordinal;
  Hashtbl.remove t.remote_end_streams state.stream_id;
  Hashtbl.remove t.remote_reset_streams state.stream_id;
  Hashtbl.remove t.remote_reset_ordinals ordinal;
  Hashtbl.remove t.pending_request_trailers ordinal;
  Hashtbl.remove t.graceful_rejected_streams state.stream_id;
  Hashtbl.remove t.streams ordinal

let forget_if_complete t ordinal state =
  if
    request_body_terminal state.request_body_state
    && response_terminal state.response_state
  then forget_stream t ordinal state

let apply_remote_end_streams t =
  let stream_ids =
    Hashtbl.fold (fun stream_id () acc -> stream_id :: acc) t.remote_end_streams
      []
  in
  List.iter
    (fun stream_id ->
      match Hashtbl.find_opt t.stream_ordinals stream_id with
      | None -> ()
      | Some ordinal -> (
          match Hashtbl.find_opt t.streams ordinal with
          | None -> ()
          | Some state ->
              request_body_peer_closed state;
              forget_if_complete t ordinal state))
    stream_ids

let resolve_unit resolver =
  Option.iter (fun resolver -> resolve resolver (Ok ())) resolver

let record_request_body_bytes t state len =
  let previous = state.request_body_bytes in
  let length = if len > max_int - previous then max_int else previous + len in
  state.request_body_bytes <- length;
  Server_stats.H2.add_request_bytes t.stats len;
  Option.iter
    (fun metrics -> Server_metrics.request_body_bytes metrics len)
    state.metrics;
  match state.request_content_length with
  | Some expected when length > expected ->
      record_protocol_error t;
      Error (request_body_length_mismatch_error t ~expected ~actual:length)
  | None | Some _ -> (
      match t.config.server.limits.max_request_body_bytes with
      | Some limit when length > limit ->
          Error (request_body_too_large_error t ~limit ~length)
      | None | Some _ -> Ok ())

let finish_request_body_eof t state =
  match state.request_content_length with
  | Some expected when state.request_body_bytes <> expected ->
      record_protocol_error t;
      Error
        (request_body_length_mismatch_error t ~expected
           ~actual:state.request_body_bytes)
  | None | Some _ -> Ok ()

let schedule_request_body_drain_timeout t ordinal token timeout =
  Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
      t.sleep timeout;
      ignore (enqueue t (Request_body_drain_timeout (ordinal, token)));
      `Stop_daemon)

let rec drain_request_body t ordinal state remaining resolver =
  if request_body_terminal state.request_body_state then (
    clear_request_discard state;
    forget_if_complete t ordinal state;
    resolve_unit resolver)
  else if remaining <= 0 then (
    fail_request_trailers state (request_body_closed_error t ordinal);
    ignore_request_body state;
    clear_request_discard state;
    forget_if_complete t ordinal state;
    resolve_unit resolver)
  else if H2.Body.Reader.is_closed state.request_body then (
    request_body_peer_closed state;
    resolve_request_trailers_empty state;
    clear_request_discard state;
    forget_if_complete t ordinal state;
    resolve_unit resolver)
  else (
    request_body_draining state;
    state.request_discard_resolver <- resolver;
    Option.iter
      (fun timeout ->
        let _promise, token = Eio.Promise.create () in
        state.request_discard_timeout_token <- Some token;
        schedule_request_body_drain_timeout t ordinal token timeout)
      t.config.server.timeouts.request_body_timeout;
    H2.Body.Reader.schedule_read state.request_body
      ~on_eof:(fun () ->
        match finish_request_body_eof t state with
        | Ok () ->
            request_body_peer_closed state;
            resolve_request_trailers_empty state;
            clear_request_discard state;
            forget_if_complete t ordinal state;
            resolve_unit resolver
        | Error error ->
            Option.iter (fun resolver -> resolve resolver (Error error)) resolver;
            fail_request_trailers state error;
            close_request_body state;
            forget_if_complete t ordinal state)
      ~on_read:(fun _bs ~off:_ ~len ->
        state.request_discard_timeout_token <- None;
        match record_request_body_bytes t state len with
        | Ok () -> drain_request_body t ordinal state (remaining - len) resolver
        | Error error ->
            Option.iter
              (fun resolver -> resolve resolver (Error error))
              resolver;
            fail_request_trailers state error;
            close_request_body state;
            forget_if_complete t ordinal state))

let discard_request_body_with_policy ?resolver ~drain t ordinal state =
  if
    request_body_terminal state.request_body_state
    || state.request_body_state = Request_body_draining
    || state.request_body_state = Request_body_ignored
  then resolve_unit resolver
  else
    match (drain, t.config.server.unread_body_policy) with
    | true, Eta_http.Server.Config.Drain_up_to limit ->
        drain_request_body t ordinal state limit resolver
    | true, Eta_http.Server.Config.Reset | false, _ ->
        fail_request_trailers state (request_body_closed_error t ordinal);
        ignore_request_body state;
        clear_request_discard state;
        forget_if_complete t ordinal state;
        resolve_unit resolver

let finish_response t ordinal state =
  if not (response_terminal state.response_state) then
    Server_stats.H2.stream_completed t.stats;
  finish_stream_metrics state;
  response_closed state;
  state.response_drain <- None;
  discard_request_body_with_policy ~drain:true t ordinal state;
  forget_if_complete t ordinal state

let complete_response_drains t =
  if not t.write_pending then (
    let drains =
      Hashtbl.fold
        (fun ordinal state acc ->
          match state.response_drain with
          | None -> acc
          | Some drain -> (ordinal, state, drain) :: acc)
        t.streams []
    in
    List.iter
      (fun (ordinal, state, { resolver; finish_on_complete }) ->
        state.response_drain <- None;
        if finish_on_complete then finish_response t ordinal state;
        resolve resolver (Ok ()))
      drains)

let flush_writes t =
  drain_writes t;
  complete_response_drains t

let flush_control_frames t =
  if (not t.closed) && (not t.write_pending) && t.pending_control_frames <> []
  then (
    let frames = List.rev t.pending_control_frames in
    t.pending_control_frames <- [];
    try
      List.iter
        (fun frame ->
          Eio.Flow.write t.flow [ Cstruct.of_string frame ])
        frames
    with _ -> mark_closed t)

let finish_deferred_close t =
  match t.deferred_close with
  | Some mode
    when (not t.closed)
         && Hashtbl.length t.streams = 0 && not t.write_pending
         && t.pending_control_frames = [] ->
      t.deferred_close <- None;
      mark_closed t;
      (match mode with
      | Close_all -> graceful_close_flow_all t.flow
      | Shutdown_send -> (try Eio.Flow.shutdown t.flow `Send with _ -> ()))
  | None | Some _ -> ()

let defer_close t mode =
  if not t.closed then (
    t.deferred_close <- Some mode;
    flush_writes t;
    flush_control_frames t;
    finish_deferred_close t)

let finish_reset_response t ordinal state =
  finish_stream_metrics state;
  response_reset state;
  discard_request_body_with_policy ~drain:true t ordinal state;
  forget_if_complete t ordinal state

let close_response_writer_best_effort state =
  match state.response_writer with
  | None -> ()
  | Some writer -> (
      try
        if not (H2.Body.Writer.is_closed writer) then H2.Body.Writer.close writer
      with _ -> ())

let fail_active_streams t request_error =
  let streams =
    Hashtbl.fold (fun ordinal state acc -> (ordinal, state) :: acc) t.streams []
  in
  Server_stats.H2.add_reset_streams t.stats (List.length streams);
  List.iter
    (fun (ordinal, state) ->
      Option.iter
        (fun metrics -> Server_metrics.stream_resets metrics 1)
        state.metrics;
      finish_stream_metrics state;
      fail_pending_request_read state request_error;
      fail_pending_request_discard state request_error;
      fail_pending_response_write state request_error;
      fail_request_trailers state request_error;
      close_request_body state;
      close_response_writer_best_effort state;
      response_reset state;
      forget_stream t ordinal state)
    streams

let finish_remote_reset_stream t ordinal state =
  Server_stats.H2.stream_reset t.stats;
  Option.iter
    (fun metrics -> Server_metrics.stream_resets metrics 1)
    state.metrics;
  finish_stream_metrics state;
  let error = connection_closed_error t Request_body in
  fail_pending_request_read state error;
  fail_pending_request_discard state error;
  fail_pending_response_write state error;
  fail_request_trailers state error;
  close_request_body state;
  close_response_writer_best_effort state;
  response_reset state;
  forget_stream t ordinal state

let apply_remote_resets t =
  let ordinals =
    Hashtbl.fold
      (fun ordinal () acc -> ordinal :: acc)
      t.remote_reset_ordinals []
  in
  List.iter
    (fun ordinal ->
      Hashtbl.remove t.remote_reset_ordinals ordinal;
      match Hashtbl.find_opt t.streams ordinal with
      | None -> ()
      | Some state -> finish_remote_reset_stream t ordinal state)
    ordinals

let request_body_open state =
  not (request_body_terminal state.request_body_state)

let fail_open_request_bodies t =
  let ordinals =
    Hashtbl.fold
      (fun ordinal state acc ->
        if request_body_open state then ordinal :: acc else acc)
      t.streams []
  in
  List.iter
    (fun ordinal ->
      match Hashtbl.find_opt t.streams ordinal with
      | None -> ()
      | Some state -> finish_remote_reset_stream t ordinal state)
    ordinals

let goaway_error_frame ~last_stream_id error_code =
  Eta_http.H2.Frame.header ~length:8 ~frame_type:Goaway ~flags:0
    ~stream_id:0
  ^ Eta_http.H2.Frame.uint32 last_stream_id
  ^ Eta_http.H2.Frame.uint32 error_code

let h2_error_code_of_kind = function
  | Eta_http.Error.Connection_protocol_violation { kind = "stream_closed"; _ } ->
      h2_stream_closed
  | Eta_http.Error.Connection_protocol_violation
      {
        kind =
          ( "h2_frame_size" | "settings_ack_length" | "settings_length"
          | "ping_length" | "rst_stream_length" | "goaway_length"
          | "priority_length" | "push_promise_length" | "window_update_length" );
        _;
      } ->
      h2_frame_size_error
  | Eta_http.Error.Connection_protocol_violation
      { kind = "settings_initial_window_size"; _ } ->
      h2_flow_control_error
  | Eta_http.Error.Hpack_decode_overflow _ | Eta_http.Error.Header_invalid _ ->
      h2_compression_error
  | Eta_http.Error.Continuation_flood _ | Eta_http.Error.Rst_count_exceeded _
  | Eta_http.Error.Ping_count_exceeded _
  | Eta_http.Error.Empty_data_frame_count_exceeded _
  | Eta_http.Error.Window_update_count_exceeded _
  | Eta_http.Error.Settings_count_exceeded _
  | Eta_http.Error.Response_header_count_exceeded _ ->
      h2_enhance_your_calm
  | Eta_http.Error.Connection_closed _ -> h2_no_error
  | _ -> h2_protocol_error

let write_goaway_error t ~code _kind =
  let frame =
    goaway_error_frame
      ~last_stream_id:t.highest_processed_stream_id
      code
  in
  try Eio.Flow.write t.flow [ Cstruct.of_string frame ] with _ -> ()

let cleanup_stream_sidecars t ordinal stream_id =
  Eta_http.H2.Security.complete_stream t.security stream_id;
  Hashtbl.remove t.stream_ordinals stream_id;
  Hashtbl.remove t.stream_ids_by_ordinal ordinal;
  Hashtbl.remove t.remote_end_streams stream_id;
  Hashtbl.remove t.remote_reset_streams stream_id;
  Hashtbl.remove t.remote_reset_ordinals ordinal;
  Hashtbl.remove t.pending_request_trailers ordinal;
  Hashtbl.remove t.graceful_rejected_streams stream_id

let cleanup_stream_sidecars_by_stream_id t stream_id =
  match Hashtbl.find_opt t.stream_ordinals stream_id with
  | None ->
      Eta_http.H2.Security.complete_stream t.security stream_id;
      Hashtbl.remove t.remote_end_streams stream_id;
      Hashtbl.remove t.remote_reset_streams stream_id;
      Hashtbl.remove t.graceful_rejected_streams stream_id
  | Some ordinal -> cleanup_stream_sidecars t ordinal stream_id

let maybe_write_graceful_goaway t =
  if t.graceful_shutdown && not t.graceful_shutdown_goaway_sent then (
    t.graceful_shutdown_goaway_sent <- true;
    enqueue_control_frame t
      (Eta_http.H2.Frame.goaway_no_error
         ~last_stream_id:(graceful_shutdown_cutoff t)));
  flush_control_frames t

let handle_security_error t ~code kind =
  let error = security_error t kind in
  record_protocol_error t;
  mark_closed t;
  fail_active_streams t error;
  flush_writes t;
  write_goaway_error t ~code kind;
  try Eio.Flow.shutdown t.flow `Send with _ -> ()

let handle_security_stream_error t ~stream_id ~code kind =
  record_protocol_error t;
  enqueue_control_frame t (rst_stream_frame ~stream_id code);
  (match Hashtbl.find_opt t.stream_ordinals stream_id with
  | Some ordinal -> (
      match Hashtbl.find_opt t.streams ordinal with
      | Some state -> finish_remote_reset_stream t ordinal state
      | None -> cleanup_stream_sidecars t ordinal stream_id)
  | None -> cleanup_stream_sidecars_by_stream_id t stream_id);
  flush_writes t;
  flush_control_frames t

let handle_security_observation t = function
  | Eta_http.H2.Security.Pass -> false
  | Eta_http.H2.Security.Connection_error { code; kind }
  | Eta_http.H2.Security.Policy_close { code; kind } ->
      handle_security_error t ~code kind;
      true
  | Eta_http.H2.Security.Stream_error { stream_id; code; kind } ->
      handle_security_stream_error t ~stream_id ~code kind;
      true

let finish_graceful_shutdown_if_idle t =
  if t.graceful_shutdown && not t.closed then (
    maybe_write_graceful_goaway t;
    if
      t.graceful_shutdown_goaway_sent
      && Hashtbl.length t.streams = 0
      && not t.write_pending && t.pending_control_frames = []
    then defer_close t Shutdown_send)

let schedule_request_body_timeout t ordinal resolver timeout =
  Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
      t.sleep timeout;
      ignore (enqueue t (Request_body_timeout (ordinal, resolver)));
      `Stop_daemon)

let arm_request_body_read t ordinal resolver =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> resolve resolver (Error (request_body_closed_error t ordinal))
  | Some state
    when not (request_body_available_to_app state.request_body_state) ->
      resolve resolver (Ok None)
  | Some state ->
      state.request_read_resolver <- Some resolver;
      H2.Body.Reader.schedule_read state.request_body
        ~on_read:(fun bs ~off ~len ->
          state.request_read_resolver <- None;
          match record_request_body_bytes t state len with
          | Error error ->
              fail_request_trailers state error;
              close_request_body state;
              forget_if_complete t ordinal state;
              resolve resolver (Error error)
          | Ok () ->
              let chunk = Bytes.create len in
              Bigstringaf.blit_to_bytes bs ~src_off:off chunk ~dst_off:0 ~len;
              resolve resolver (Ok (Some chunk)))
        ~on_eof:(fun () ->
          state.request_read_resolver <- None;
          match finish_request_body_eof t state with
          | Ok () ->
              request_body_peer_closed state;
              resolve_request_trailers_empty state;
              forget_if_complete t ordinal state;
              resolve resolver (Ok None)
          | Error error ->
              fail_request_trailers state error;
              close_request_body state;
              forget_if_complete t ordinal state;
              resolve resolver (Error error));
      (* Only arm a body-read timeout if the read did not complete synchronously.
         schedule_read delivers already-buffered DATA inline (clearing the
         resolver), which is the common case for small request bodies. Skipping
         the arm avoids a per-read fork_daemon + Zzz sleeper on the hot path. *)
      if Option.is_some state.request_read_resolver then
        Option.iter
          (schedule_request_body_timeout t ordinal resolver)
          t.config.server.timeouts.request_body_timeout

let handle_request_body_timeout t ordinal resolver =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> ()
  | Some state -> (
      match state.request_read_resolver with
      | Some active when active == resolver ->
          let error =
            request_timeout_error t t.config.server.timeouts.request_body_timeout
          in
          state.request_read_resolver <- None;
          resolve resolver (Error error);
          fail_request_trailers state error;
          close_request_body state;
          forget_if_complete t ordinal state
      | None | Some _ -> ())

let handle_request_body_drain_timeout t ordinal token =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> ()
  | Some state -> (
      match state.request_discard_timeout_token with
      | Some active when active == token ->
          let error =
            request_timeout_error t t.config.server.timeouts.request_body_timeout
          in
          let resolver = state.request_discard_resolver in
          Option.iter (fun resolver -> resolve resolver (Error error)) resolver;
          fail_request_trailers state error;
          close_request_body state;
          forget_if_complete t ordinal state
      | None | Some _ -> ())

let discard_request_body t ordinal _drain resolver =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> resolve resolver (Ok ())
  | Some state ->
      discard_request_body_with_policy ?resolver:(Some resolver) ~drain:_drain t
        ordinal state

let start_response t ordinal response resolver =
  match Hashtbl.find_opt t.streams ordinal with
  | None ->
      resolve resolver (Error (response_write_error t ()));
      `Done
  | Some state when response_terminal state.response_state ->
      resolve resolver
        (Error
           (response_write_error t ~message:"response already completed" ()));
      `Done
  | Some state -> (
      match response.body with
      | Response_fixed (_, length) when length > max_h2_data_chunk ->
          let writer =
            H2.Connection.Server.Reqd.respond_with_streaming state.reqd
              (h2_response response)
          in
          response_streaming state;
          state.response_writer <- Some writer;
          state.response_drain <- Some { resolver; finish_on_complete = false };
          discard_request_body_with_policy ~drain:true t ordinal state;
          `Flush (state, resolver)
      | Response_no_body _ | Response_fixed _ ->
          (match response.body with
          | Response_no_body _ -> ()
          | Response_fixed (_, length) ->
              Server_stats.H2.add_response_bytes t.stats length;
              Option.iter
                (fun metrics ->
                  Server_metrics.response_body_bytes metrics length)
                state.metrics
          | Response_stream _ -> assert false);
          respond_fixed state.reqd response;
          finish_response t ordinal state;
          resolve resolver (Ok ());
          `Done
      | Response_stream _ ->
          let writer =
            H2.Connection.Server.Reqd.respond_with_streaming state.reqd
              (h2_response response)
          in
          response_streaming state;
          state.response_writer <- Some writer;
          state.response_drain <- Some { resolver; finish_on_complete = false };
          discard_request_body_with_policy ~drain:true t ordinal state;
          `Flush (state, resolver))

let write_response_chunk t ordinal chunk resolver =
  let fail message = resolve resolver (Error (response_write_error t ~message ())) in
  match Hashtbl.find_opt t.streams ordinal with
  | None -> resolve resolver (Error (response_write_error t ()))
  | Some { response_writer = None; _ } ->
      fail "response streaming writer has not been started"
  | Some ({ response_writer = Some writer; _ } as state) ->
      if H2.Body.Writer.is_closed writer then
        fail "response writer is closed"
      else
        match write_fixed_chunk writer chunk with
        | Error message -> fail message
        | Ok () ->
            Server_stats.H2.add_response_bytes t.stats (Bytes.length chunk);
            Option.iter
              (fun metrics ->
                Server_metrics.response_body_bytes metrics (Bytes.length chunk))
              state.metrics;
            state.response_write_resolver <- Some resolver;
            H2.Body.Writer.flush writer (fun () ->
                state.response_write_resolver <- None;
                if H2.Body.Writer.is_closed writer then
                  fail "response flush closed"
                else resolve resolver (Ok ()))

let schedule_response_trailers t ordinal trailers resolver =
  match
    Server.Validation.validate_h2_response_trailers
      ~limits:t.config.server.limits trailers
  with
  | Error message ->
      resolve resolver
        (Error
           (response_write_error t
              ~message ()));
      `Done
  | Ok () -> (
      match Hashtbl.find_opt t.streams ordinal with
      | None ->
          resolve resolver (Error (response_write_error t ()));
          `Done
      | Some state -> (
          try
            if not (List.is_empty trailers) then
              H2.Connection.Server.Reqd.schedule_trailers state.reqd
                (List.map
                   (fun (name, value) ->
                     (Eta_http.Core.Header.normalize_name name, value))
                   trailers);
            state.response_drain <- Some { resolver; finish_on_complete = false };
            `Flush (state, resolver)
          with exn ->
            resolve resolver
              (Error
                 (response_write_error t ~message:(Printexc.to_string exn) ()));
            `Done))

let close_response_writer t ordinal resolver =
  match Hashtbl.find_opt t.streams ordinal with
  | None ->
      resolve resolver (Error (response_write_error t ()));
      `Done
  | Some { response_writer = None; _ } ->
      resolve resolver
        (Error
           (response_write_error t
              ~message:"response streaming writer has not been started" ()));
      `Done
  | Some state -> (
      match state.response_writer with
      | None -> assert false
      | Some writer ->
          (try
             if not (H2.Body.Writer.is_closed writer) then
               H2.Body.Writer.close writer
           with _ -> ());
          state.response_drain <- Some { resolver; finish_on_complete = true };
          `Flush (state, resolver))

let fail_response t ordinal error =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> ()
  | Some state ->
      Server_stats.H2.stream_reset t.stats;
      Option.iter
        (fun metrics -> Server_metrics.stream_resets metrics 1)
        state.metrics;
      H2.Connection.Server.Reqd.report_exn state.reqd
        (Failure (Server.Error.to_string error));
      finish_reset_response t ordinal state

let begin_immediate_shutdown t =
  if not t.closed then (
    t.deferred_close <- None;
    mark_closed t;
    fail_active_streams t (shutdown_error t);
    abortive_close_flow t.flow)

let start_shutdown_timer t timeout =
  if not t.shutdown_timer_started then (
    t.shutdown_timer_started <- true;
    Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
        t.sleep timeout;
        ignore (enqueue t (Shutdown Immediate));
        `Stop_daemon))

let cancel_idle_timeout t = t.idle_timeout_token <- None

let schedule_idle_timeout_if_idle t =
  if
    (not t.closed)
    && t.accepted_request && Hashtbl.length t.streams = 0
    && Option.is_none t.idle_timeout_token
  then
    match t.config.server.timeouts.idle_timeout with
    | None -> ()
    | Some timeout ->
        let _promise, token = Eio.Promise.create () in
        t.idle_timeout_token <- Some token;
        Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
            t.sleep timeout;
            ignore (enqueue t (Idle_timeout token));
            `Stop_daemon)

let handle_idle_timeout t token =
  match t.idle_timeout_token with
  | Some active when active == token && Hashtbl.length t.streams = 0 ->
      t.idle_timeout_token <- None;
      mark_closed t;
      fail_active_streams t
        (request_timeout_error t t.config.server.timeouts.idle_timeout);
      graceful_close_flow_all t.flow
  | None | Some _ -> ()

let incomplete_header_block_eof_error =
  h2_filter_protocol_violation ~kind:"h2_incomplete_header_block"
    ~message:"HTTP/2 connection closed with an incomplete header block"

let begin_graceful_shutdown t timeout =
  if Eta.Duration.is_zero timeout then begin_immediate_shutdown t
  else if not t.closed then (
    t.graceful_shutdown <- true;
    if Option.is_none t.graceful_shutdown_last_stream_id then
      t.graceful_shutdown_last_stream_id <- Some t.highest_processed_stream_id;
    start_shutdown_timer t timeout;
    maybe_write_graceful_goaway t;
    finish_graceful_shutdown_if_idle t)

let begin_shutdown t = function
  | Types.Immediate ->
      emit_connection_metric t (fun metrics ->
          Server_metrics.shutdown_active metrics 1);
      begin_immediate_shutdown t
  | Types.Graceful timeout ->
      emit_connection_metric t (fun metrics ->
          Server_metrics.shutdown_active metrics 1);
      begin_graceful_shutdown t timeout

let handle_command t = function
  | Ingress { bytes; off; len; ack } ->
      cancel_idle_timeout t;
      Fun.protect
    ~finally:(fun () -> resolve ack ())
    (fun () ->
          let observation = observe_ingress_security t bytes ~off ~len in
          if handle_security_observation t observation then ()
          else (
              match filter_ingress t bytes ~off ~len with
              | Error observation ->
                  ignore (handle_security_observation t observation)
              | Ok None ->
                  flush_writes t
              | Ok (Some (bytes, len)) -> (
                  match append_ingress t bytes ~off:0 ~len with
                  | Error error ->
                      record_protocol_error t;
                      mark_closed t;
                      fail_active_streams t error;
                      graceful_close_flow_all t.flow
                  | Ok () ->
                      feed_ingress t;
                      apply_remote_end_streams t;
                      apply_remote_resets t;
                      flush_writes t)))
  | Ingress_eof ->
      if Eta_http.H2.Security.has_open_header_block t.security then
        handle_security_error t
          ~code:(h2_error_code_of_kind incomplete_header_block_eof_error)
          incomplete_header_block_eof_error
      else (
        read_eof t;
        apply_remote_end_streams t;
        apply_remote_resets t;
        fail_open_request_bodies t;
        flush_writes t;
        defer_close t Close_all)
  | Ingress_failed error ->
      mark_closed t;
      fail_active_streams t error;
      graceful_close_flow_all t.flow
  | Idle_timeout token ->
      handle_idle_timeout t token
  | Request_body_read (ordinal, resolver) ->
      arm_request_body_read t ordinal resolver;
      flush_writes t
  | Request_body_timeout (ordinal, resolver) ->
      handle_request_body_timeout t ordinal resolver;
      flush_writes t
  | Request_body_drain_timeout (ordinal, token) ->
      handle_request_body_drain_timeout t ordinal token;
      flush_writes t
  | Request_body_discard (ordinal, drain, resolver) ->
      discard_request_body t ordinal drain resolver;
      flush_writes t
  | Response_start (ordinal, response, resolver) ->
      (match start_response t ordinal response resolver with
      | `Done -> flush_writes t
      | `Flush _ -> flush_writes t)
  | Response_chunk (ordinal, chunk, resolver) ->
      write_response_chunk t ordinal chunk resolver;
      flush_writes t
  | Response_trailers (ordinal, trailers, resolver) ->
      (match schedule_response_trailers t ordinal trailers resolver with
      | `Done -> flush_writes t
      | `Flush _ -> flush_writes t)
  | Response_close (ordinal, resolver) ->
      (match close_response_writer t ordinal resolver with
      | `Done -> flush_writes t
      | `Flush _ -> flush_writes t)
  | Response_failed (ordinal, error) ->
      fail_response t ordinal error;
      flush_writes t
  | Write_completed (Ok written) ->
      if t.write_pending then (
        t.write_pending <- false;
        H2.Connection.report_write_result t.h2 (`Ok written);
        flush_writes t;
        flush_control_frames t)
  | Write_completed (Error error) ->
      if t.write_pending then t.write_pending <- false;
      (try H2.Connection.report_write_result t.h2 `Closed with _ -> ());
      mark_closed t;
      fail_active_streams t error;
      graceful_close_flow_all t.flow
  | Shutdown policy ->
      begin_shutdown t policy;
      flush_writes t;
      flush_control_frames t

let rec owner_loop t =
  if (not t.closed) && not (H2.Connection.is_closed t.h2) then (
    flush_writes t;
    flush_control_frames t;
    let command = Eio.Stream.take t.commands in
    handle_command t command;
    finish_graceful_shutdown_if_idle t;
    finish_deferred_close t;
    schedule_idle_timeout_if_idle t;
    owner_loop t)

let reader_loop t =
  let scratch = Bigstringaf.create t.config.read_buffer_size in
  let cstruct = Cstruct.of_bigarray scratch in
  let ingress_timeout () =
    if Hashtbl.length t.streams = 0 then
      if t.accepted_request then t.config.server.timeouts.idle_timeout
      else t.config.server.timeouts.request_header_timeout
    else None
  in
  let single_read () =
    let read () =
      match ingress_timeout () with
      | None -> `Read (Eio.Flow.single_read t.flow cstruct)
      | Some timeout -> (
          try
            `Read
              (t.with_timeout timeout (fun () ->
                   Eio.Flow.single_read t.flow cstruct))
          with Eio.Time.Timeout -> `Timeout timeout)
    in
    (* Close is delivered via cancellation of the handler switch (which this
       fiber runs under) rather than a per-read [Fiber.first] race against
       [closed_signal], avoiding a fiber + cancel context per read. *)
    read ()
  in
  let rec loop () =
    match single_read () with
    | `Timeout timeout ->
        ignore
          (enqueue t (Ingress_failed (request_timeout_error t (Some timeout))))
    | `Read 0 -> ignore (enqueue t Ingress_eof)
    | `Read len ->
        Bigstringaf.blit scratch ~src_off:0 t.read_owned ~dst_off:0 ~len;
        let promise, ack = Eio.Promise.create () in
        if enqueue t (Ingress { bytes = t.read_owned; off = 0; len; ack }) then (
          (* Ack/close delivered via handler-switch cancellation, not a
             per-ingress Fiber.first race. *)
          Eio.Promise.await promise;
          loop ())
    | exception End_of_file -> ignore (enqueue t Ingress_eof)
    | exception Eio.Cancel.Cancelled _ -> ()
    | exception exn ->
        ignore (enqueue t (Ingress_failed (connection_read_error t exn)))
  in
  loop ()

let write_job t job =
  let write () =
    (* Close is delivered via handler-switch cancellation; the outer finally
       still does graceful_close_flow_all, so the flow is closed on teardown. *)
    Eio.Flow.write t.flow [ job.data ];
    job.len
  in
  match t.config.server.timeouts.response_write_timeout with
  | None -> write ()
  | Some timeout -> t.with_timeout timeout write

let writer_loop t =
  let take_job () = `Job (Eio.Stream.take t.write_jobs) in
  let rec loop () =
    if not t.closed then
      match take_job () with
      | `Job job ->
          if t.closed then ()
          else (
            let result =
              try Ok (write_job t job) with
              | Eio.Cancel.Cancelled _ as exn -> raise exn
              | Eio.Time.Timeout -> Error (response_write_timeout_error t)
              | exn -> Error (connection_write_error t exn)
            in
            if enqueue t (Write_completed result) then loop ())
  in
  try loop () with Eio.Cancel.Cancelled _ -> ()

(* Per-connection handler-timeout watchdog. Each in-flight handler registers a
   deadline + its cancel context in [t.handler_watches]; this single daemon
   polls and cancels any handler whose deadline has passed. This replaces the
   per-request Eio.Time.with_timeout (sleeper fiber + Zzz timer node per
   request) with O(1) zero-alloc arming. Poll cadence scales with the timeout
   so short test timeouts still fire promptly. *)
let watchdog_loop t =
  match t.config.server.timeouts.handler_timeout with
  | None -> ()
  | Some timeout ->
      let poll = Eta.Duration.ms (max 1 (Eta.Duration.to_ms timeout / 8)) in
      let rec loop () =
        if not t.closed then (
          t.sleep poll;
          (if (not t.closed) && Hashtbl.length t.handler_watches > 0 then
             let now = Int64.to_int (t.now_ms ()) in
             let expired =
               Hashtbl.fold
                 (fun _ w acc -> if now > w.hw_deadline then w :: acc else acc)
                 t.handler_watches []
             in
             List.iter
               (fun w -> Eio.Cancel.cancel w.hw_cancel Eio.Time.Timeout)
               expired);
          loop ())
      in
      loop ()

let fail_owner_loop t error =
  mark_closed t;
  fail_active_streams t error;
  graceful_close_flow_all t.flow

let run_owner_loop t =
  try owner_loop t
  with
  | Eio.Cancel.Cancelled _ -> fail_owner_loop t (shutdown_error t)
  | Eio.Time.Timeout -> fail_owner_loop t (response_write_timeout_error t)
  | exn -> fail_owner_loop t (connection_write_error t exn)

let await_owner t make =
  if t.closed then Error (connection_closed_error t Response_body)
  else
    let promise, resolver = Eio.Promise.create () in
    if enqueue t (make resolver) then
      (* Close is delivered by cancellation of the handler switch (handlers run
         under [t.handler_sw]) rather than a per-call [Fiber.first] race. *)
      Eio.Promise.await promise
    else Error (connection_closed_error t Response_body)

(* Response-write commands resolve only once their data is flushed to the
   transport. When a stream is flow-control blocked (the peer withholds
   WINDOW_UPDATE / never reads the body), that flush never completes, so bound
   the wait by [response_write_timeout]. Otherwise a non-reading client could
   pin a stream open indefinitely. *)
let await_owner_write t make =
  match t.config.server.timeouts.response_write_timeout with
  | None -> await_owner t make
  | Some timeout -> (
      try t.with_timeout timeout (fun () -> await_owner t make)
      with Eio.Time.Timeout -> Error (response_write_timeout_error t))

let response_error_of_cause t cause =
  match find_failure cause with
  | Some error -> error
  | None -> response_failure_of_cause t cause

let release_response_stream rt stream =
  match Eta.Runtime.run rt (stream.Server.Response.Body.release ()) with
  | Eta.Exit.Ok () | Eta.Exit.Error _ -> ()

let release_ignored_response_stream rt response =
  match Server.Response.body response with
  | Server.Response.Body.Stream stream -> release_response_stream rt stream
  | Empty | Fixed _ -> ()

let release_prepared_response_body rt response =
  match response.body with
  | Response_no_body (Some stream) | Response_stream stream ->
      release_response_stream rt stream
  | Response_no_body None | Response_fixed _ -> ()

let handler_failed_error t request exn =
  let message = Printexc.to_string exn in
  Server.Error.make ~protocol:t.connection.protocol
    ~method_:request.Server.Request.method_ ~target:request.target
    (Handler_failed { message })

let run_response_body_effect t rt request effect_thunk =
  let run () =
    try
      let effect = effect_thunk () in
      match Eta.Runtime.run rt effect with
      | Eta.Exit.Ok value -> Ok value
      | Eta.Exit.Error cause -> Error (response_error_of_cause t cause)
    with
    | Eio.Cancel.Cancelled _ as exn -> Error (handler_failed_error t request exn)
    | exn -> Error (handler_failed_error t request exn)
  in
  match t.config.server.timeouts.response_body_timeout with
  | Some timeout -> (
      try t.with_timeout timeout run
      with Eio.Time.Timeout ->
        Error (response_body_timeout_error t request (Some timeout)))
  | None -> run ()

let read_response_stream t rt request stream =
  Eio.Fiber.first
    (fun () ->
      `Read
        (run_response_body_effect t rt request (fun () ->
             stream.Server.Response.Body.read ())))
    (fun () ->
      Eio.Promise.await t.closed_signal;
      `Closed)

let response_trailers t rt request response =
  Eio.Fiber.first
    (fun () ->
      `Trailers
        (run_response_body_effect t rt request (fun () ->
             (Server.Response.trailers response) ())))
    (fun () ->
      Eio.Promise.await t.closed_signal;
      `Closed)

let fail_stream_response t rt ordinal stream error =
  ignore (enqueue t (Response_failed (ordinal, error)));
  release_response_stream rt stream

let response_content_length_error t message =
  response_write_error t ~message ()

let rec pump_response_stream t rt ordinal request response stream written =
  match read_response_stream t rt request stream with
  | `Closed -> release_response_stream rt stream
  | `Read (Error error) -> fail_stream_response t rt ordinal stream error
  | `Read (Ok (Some chunk)) -> (
      let length = Bytes.length chunk in
      let next = if length > max_int - written then max_int else written + length in
      match stream.Server.Response.Body.length with
      | Some expected when next > expected ->
          fail_stream_response t rt ordinal stream
            (response_content_length_error t
               "stream exceeded declared Content-Length")
      | None | Some _ -> (
          match
            await_owner_write t (fun resolver ->
                Response_chunk (ordinal, chunk, resolver))
          with
          | Ok () -> pump_response_stream t rt ordinal request response stream next
          | Error error -> fail_stream_response t rt ordinal stream error))
  | `Read (Ok None) -> (
      match stream.Server.Response.Body.length with
      | Some expected when written <> expected ->
          fail_stream_response t rt ordinal stream
            (response_content_length_error t
               "stream ended before declared Content-Length")
      | None | Some _ -> (
          match response_trailers t rt request response with
          | `Closed -> release_response_stream rt stream
          | `Trailers (Error error) ->
              fail_stream_response t rt ordinal stream error
          | `Trailers (Ok trailers) -> (
              match
                await_owner_write t (fun resolver ->
                    Response_trailers (ordinal, trailers, resolver))
              with
              | Error error -> fail_stream_response t rt ordinal stream error
              | Ok () -> (
                  match
                    await_owner_write t (fun resolver ->
                        Response_close (ordinal, resolver))
                  with
                  | Ok () -> release_response_stream rt stream
                  | Error error ->
                      fail_stream_response t rt ordinal stream error))))

let safe_handler_effect t request handler =
  try
    Eta_http.Observability.Server.Tracer.request
      ~enabled:t.config.server.enable_otel
      ~emit_url_full:t.config.server.emit_url_full
      handler request
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn -> Eta.Effect.fail (handler_failed_error t request exn)

let run_handler_body t ordinal request handler =
  let rt = t.runtime in
  let effect = safe_handler_effect t request handler in
  let response =
    match t.config.server.timeouts.handler_timeout with
    | Some timeout -> (
        (* Cheap handler timeout: register a deadline + this fiber's cancel
           context for the watchdog, instead of arming a per-request Eio timer
           (which forks a sleeper fiber + Zzz node). The watchdog cancels the
           context if the deadline passes; cancellation surfaces as Cancelled
           and is mapped to the handler-timeout response. *)
        let deadline =
          Int64.to_int (t.now_ms ()) + Eta.Duration.to_ms timeout
        in
        let run () =
          Eio.Cancel.sub (fun cc ->
              Hashtbl.replace t.handler_watches ordinal
                { hw_deadline = deadline; hw_cancel = cc };
              match Eta.Runtime.run rt effect with
              | result ->
                  Hashtbl.remove t.handler_watches ordinal;
                  result
              | exception exn ->
                  Hashtbl.remove t.handler_watches ordinal;
                  raise exn)
        in
        match run () with
        | Eta.Exit.Ok response -> response
        | Eta.Exit.Error cause -> fallback_error_response t request cause
        | exception Eio.Cancel.Cancelled _ ->
            Server.Handler.default_error_response
              (handler_timeout_error t request (Some timeout)))
    | None -> (
        match Eta.Runtime.run rt effect with
        | Eta.Exit.Ok response -> response
        | Eta.Exit.Error cause -> fallback_error_response t request cause)
  in
  let response, prepared =
    match prepare_h2_response t request response with
    | Ok prepared -> (response, Ok prepared)
    | Error error ->
        release_ignored_response_stream rt response;
        let response = Server.Handler.default_error_response error in
        (response, prepare_h2_response t request response)
  in
  match prepared with
  | Error error -> ignore (enqueue t (Response_failed (ordinal, error)))
  | Ok prepared -> (
      match
        await_owner t (fun resolver -> Response_start (ordinal, prepared, resolver))
      with
      | Error error ->
          release_prepared_response_body rt prepared;
          ignore (enqueue t (Response_failed (ordinal, error)))
      | Ok () -> (
          match prepared.body with
          | Response_fixed (chunks, length) when length > max_h2_data_chunk ->
              pump_response_stream t rt ordinal request response
                (fixed_response_stream chunks length) 0
          | Response_no_body (Some stream) -> release_response_stream rt stream
          | Response_no_body None | Response_fixed _ -> ()
          | Response_stream stream ->
              pump_response_stream t rt ordinal request response stream 0))

(* Sentinel used to cancel all in-flight handler fibers at connection close
   without propagating a real error out of the handler switch. *)
exception Handlers_cancelled

(* Handler fibers run on a dedicated per-connection switch [t.handler_sw] so a
   single [Switch.fail] on close cancels every in-flight handler at once. This
   replaces the old per-request [Eio.Fiber.first] race against [closed_signal],
   which forked an extra fiber + cancellation context on every request. *)
let run_handler t ordinal request handler =
  match t.handler_sw with
  | Some sw when not t.closed ->
      Eio.Fiber.fork ~sw (fun () ->
          run_handler_body t ordinal request handler)
  | _ -> ()

let shutdown t policy =
  if not t.closed then (
    let queued = enqueue t (Shutdown policy) in
    match policy with
    | Types.Immediate when queued -> abortive_close_flow t.flow
    | Immediate | Graceful _ -> ())

let run ~sw ~clock ?time ~flow ~connection ~config ~runtime_factory ?on_start
    ?on_close handler =
  validate_config config;
  let time = Option.value time ~default:(Types.live_time clock) in
  let h2_config = limited_h2_config config in
  let runtime = runtime_factory ~sw ~connection () in
  let request_ordinal = ref 0 in
  let holder = ref None in
  let h2 =
    H2.Connection.Server.create ~config:(H2.Config.to_settings h2_config)
      ~error_handler:(fun _error -> Option.iter record_protocol_error !holder)
      ~request_handler:(fun reqd ->
        match !holder with
        | None ->
            H2.Connection.Server.Reqd.report_exn reqd
              (Failure "Eta_http_eio.H2.Server_connection owner not initialized")
        | Some t ->
            t.accepted_request <- true;
            incr request_ordinal;
            let ordinal = !request_ordinal in
            (match Hashtbl.find_opt t.stream_ids_by_ordinal ordinal with
            | None ->
                H2.Connection.Server.Reqd.report_exn reqd
                  (Failure
                     "Eta_http_eio.H2.Server_connection missing observed H2 \
                      stream id")
            | Some stream_id ->
                note_processed_stream_id t stream_id;
                let body = body_of_stream t ordinal in
                let request_trailers = create_request_trailers () in
                (match Hashtbl.find_opt t.pending_request_trailers ordinal with
                | None -> ()
                | Some trailers ->
                    Hashtbl.remove t.pending_request_trailers ordinal;
                    resolve request_trailers.resolver (Ok trailers));
                let request =
                  request_of_reqd ~connection ~ordinal ~stream_id ~body
                    ~trailers:request_trailers reqd
                in
                let metrics =
                  request_metrics ~config:t.config ~runtime:t.runtime
                    ~connection:t.connection request
                in
                Option.iter Server_metrics.request_started metrics;
                Option.iter Server_metrics.stream_started metrics;
                Server_stats.H2.stream_opened t.stats;
                Hashtbl.add t.streams ordinal
                  {
                    stream_id;
                    reqd;
                    request_body = H2.Connection.Server.Reqd.request_body reqd;
                    request_content_length =
                      (match
                         Server.Validation.h2_request_content_length
                           (Eta_http.Core.Header.to_list request.headers)
                       with
                      | Ok content_length -> content_length
                      | Error _ -> None);
                    metrics;
                    metrics_finished = false;
                    request_body_bytes = 0;
                    request_body_state =
                      (if Hashtbl.mem t.remote_end_streams stream_id then
                         Request_body_peer_closed
                       else Request_body_open);
                    request_trailers;
                    request_read_resolver = None;
                    request_discard_resolver = None;
                    request_discard_timeout_token = None;
                    response_writer = None;
                    response_write_resolver = None;
                    response_drain = None;
                    response_state = Response_idle;
                  };
                (match validate_request_metadata t request with
                | Ok () -> run_handler t ordinal request handler
                | Error error ->
                    record_protocol_error t;
                    let _promise, resolver = Eio.Promise.create () in
                    let response = Server.Handler.default_error_response error in
                    (match prepare_h2_response t request response with
                    | Ok prepared ->
                        ignore (start_response t ordinal prepared resolver)
                    | Error error ->
                        ignore (enqueue t (Response_failed (ordinal, error))))))
      )
  ()
  in
  let security =
    Eta_http.H2.Security.create
      ?config:config.Types.Config.h2_security_config ()
  in
  let closed_signal, close_signal = Eio.Promise.create () in
  let t =
    let max_ingress_buffer_size = max_ingress_buffer_size config in
    {
      sw;
      now_ms = time.now_ms;
      sleep = time.sleep;
      with_timeout = time.with_timeout;
      flow;
      h2;
      security;
      security_preface_remaining = h2_client_connection_preface_length;
      ingress_buffer = Bigstringaf.create max_ingress_buffer_size;
      max_ingress_buffer_size;
      ingress_off = 0;
      ingress_len = 0;
      filter_preface_remaining = h2_client_connection_preface_length;
      filter_pending = "";
      request_header_decoder = Eta_http.Hpack.create 4096;
      request_header_encoder = Eta_http.Hpack.encoder_create 4096;
      encoder_buffer = Bytes.create 4096;
      normalize_request_headers = false;
      request_header_block = None;
      observed_request_ordinal = 0;
      highest_observed_client_stream_id = 0;
      highest_processed_stream_id = 0;
      graceful_shutdown_last_stream_id = None;
      graceful_shutdown_goaway_sent = false;
      graceful_rejected_header_stream = None;
      stream_ordinals = Hashtbl.create (stream_table_initial_capacity h2_config);
      stream_ids_by_ordinal = Hashtbl.create (stream_table_initial_capacity h2_config);
      graceful_rejected_streams = Hashtbl.create 16;
      pending_request_trailers = Hashtbl.create 16;
      remote_end_streams = Hashtbl.create 16;
      remote_reset_streams = Hashtbl.create 16;
      remote_reset_ordinals = Hashtbl.create 16;
      pending_control_frames = [];
      commands = Eio.Stream.create config.command_queue_capacity;
      write_jobs = Eio.Stream.create 1;
      streams = Hashtbl.create (stream_table_initial_capacity h2_config);
      connection;
      config;
      runtime_factory;
      runtime;
      stats = Server_stats.H2.create ();
      connection_metrics =
        connection_metrics ~config ~runtime ~connection;
      closed_signal;
      close_signal;
      handler_sw = None;
      handler_watches = Hashtbl.create 16;
      idle_timeout_token = None;
      graceful_shutdown = false;
      shutdown_timer_started = false;
      accepted_request = false;
      deferred_close = None;
      write_pending = false;
      write_buffer = Cstruct.create max_h2_data_chunk;
      emit_buffer = Buffer.create 256;
      read_owned = Bigstringaf.create config.read_buffer_size;
      closed = false;
    }
  in
  holder := Some t;
  Option.iter
    (fun metrics -> Server_metrics.active_connections metrics 1)
    t.connection_metrics;
  Option.iter (fun on_start -> on_start t) on_start;
  Fun.protect
    ~finally:(fun () ->
      mark_closed t;
      fail_active_streams t (shutdown_error t);
      Option.iter
        (fun metrics -> Server_metrics.active_connections metrics 0)
        t.connection_metrics;
      Option.iter
        (fun metrics -> Server_metrics.shutdown_active metrics 0)
        t.connection_metrics;
      H2.Connection.shutdown h2;
      graceful_close_flow_all flow;
      Option.iter (fun on_close -> on_close (stats t)) on_close)
	    (fun () ->
	      try
	        Eio.Switch.run (fun handler_sw ->
	            t.handler_sw <- Some handler_sw;
	            Eio.Fiber.fork_daemon ~sw (fun () -> watchdog_loop t; `Stop_daemon);
	            Eio.Fiber.fork ~sw:handler_sw (fun () -> writer_loop t);
	            Eio.Fiber.fork ~sw:handler_sw (fun () -> reader_loop t);
	            run_owner_loop t;
	            (* Connection closing: stop accepting new handler forks, then
	               cancel any in-flight handler fibers in one shot. *)
	            t.handler_sw <- None;
	            Eio.Switch.fail handler_sw Handlers_cancelled)
	      with Handlers_cancelled -> ())

let run_h2c ~sw ~clock ?time ~flow ~peer ~config ~runtime_factory ?on_start
    ?on_close handler =
  let connection =
    {
      Types.Connection_info.id = connection_id ();
      peer = peer_of_sockaddr peer;
      protocol = Eta_http.Server.Error.H2c;
      tls = false;
      alpn_protocol = Some "h2c";
    }
  in
  run ~sw ~clock ?time ~flow ~connection ~config ~runtime_factory ?on_start
    ?on_close handler
