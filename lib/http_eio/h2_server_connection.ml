(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Server = Eta_http.Server
module Types = Server_types

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
  sleep : Eta.Duration.t -> unit;
  with_timeout : 'a. Eta.Duration.t -> (unit -> 'a) -> 'a;
}

type request_body_read = (bytes option, Server.Error.t) result
type unit_result = (unit, Server.Error.t) result

type response_body =
  | Response_no_body of Server.Response.Body.stream option
  | Response_fixed of bytes list * int
  | Response_stream of Server.Response.Body.stream

type prepared_response = {
  status : int;
  headers : Eta_http.Core.Header.t;
  body : response_body;
}

type command =
  | Ingress of {
      bytes : Bigstringaf.t;
      off : int;
      len : int;
      ack : unit Eio.Promise.u;
    }
  | Ingress_eof
  | Ingress_failed of Server.Error.t
  | Request_body_read of int * request_body_read Eio.Promise.u
  | Request_body_timeout of int * request_body_read Eio.Promise.u
  | Request_body_drain_timeout of int * unit Eio.Promise.u
  | Request_body_discard of int * bool * (unit, Server.Error.t) result Eio.Promise.u
  | Response_start of int * prepared_response * unit_result Eio.Promise.u
  | Response_chunk of int * bytes * unit_result Eio.Promise.u
  | Response_trailers of int * Eta_http.Core.Header.t * unit_result Eio.Promise.u
  | Response_close of int * unit_result Eio.Promise.u
  | Response_failed of int * Server.Error.t
  | Shutdown of Types.shutdown

type stream_state = {
  reqd : H2.Reqd.t;
  request_body : H2.Body.Reader.t;
  request_content_length : int option;
  metrics : Server_metrics.t option;
  mutable metrics_finished : bool;
  mutable request_body_bytes : int;
  mutable request_done : bool;
  mutable request_discarding : bool;
  mutable request_read_resolver : request_body_read Eio.Promise.u option;
  mutable request_discard_resolver :
    (unit, Server.Error.t) result Eio.Promise.u option;
  mutable request_discard_timeout_token : unit Eio.Promise.u option;
  mutable response_writer : H2.Body.Writer.t option;
  mutable response_write_resolver : unit_result Eio.Promise.u option;
  mutable response_done : bool;
}

type t = {
  sw : Eio.Switch.t;
  sleep : Eta.Duration.t -> unit;
  with_timeout : 'a. Eta.Duration.t -> (unit -> 'a) -> 'a;
  flow : flow;
  h2 : H2.Server_connection.t;
  security : Eta_http.H2.Security.t;
  mutable security_preface_remaining : int;
  ingress_buffer : Bigstringaf.t;
  max_ingress_buffer_size : int;
  mutable ingress_off : int;
  mutable ingress_len : int;
  mutable filter_preface_remaining : int;
  mutable filter_pending : string;
  mutable observed_request_ordinal : int;
  stream_ordinals : (int, int) Hashtbl.t;
  remote_reset_streams : (int, unit) Hashtbl.t;
  remote_reset_ordinals : (int, unit) Hashtbl.t;
  mutable filter_rst_stream_seen : int;
  mutable filter_error : Eta_http.Error.kind option;
  commands : command Eio.Stream.t;
  streams : (int, stream_state) Hashtbl.t;
  connection : Types.Connection_info.t;
  config : Types.Config.t;
  runtime_factory : Types.runtime_factory;
  stats : Server_stats.H2.t;
  connection_metrics : Server_metrics.t option;
  closed_signal : unit Eio.Promise.t;
  close_signal : unit Eio.Promise.u;
  mutable reader_wakeup : unit Eio.Promise.t;
  mutable reader_wakeup_resolver : unit Eio.Promise.u;
  mutable graceful_shutdown : bool;
  mutable shutdown_timer_started : bool;
  mutable accepted_request : bool;
  mutable closed : bool;
}

let reset_reader_wakeup t =
  let promise, resolver = Eio.Promise.create () in
  t.reader_wakeup <- promise;
  t.reader_wakeup_resolver <- resolver

let wake_reader t =
  ignore (Eio.Promise.try_resolve t.reader_wakeup_resolver ())

let mark_closed t =
  if not t.closed then (
    t.closed <- true;
    ignore (Eio.Promise.try_resolve t.close_signal ()))

let close_flow_all flow =
  (try Eio.Flow.shutdown flow `All with _ -> ());
  try Eio.Flow.close flow with _ -> ()

let stats t =
  Server_stats.H2.snapshot t.stats
    ~active_streams:(Hashtbl.length t.streams)

let request_metrics ~sw ~config ~runtime_factory ~connection request =
  if config.Types.Config.server.enable_otel then
    let runtime = runtime_factory ~sw ~connection () in
    Some
      (Server_metrics.request ~runtime ~connection
         ~emit_url_full:config.server.emit_url_full request)
  else None

let connection_metrics ~sw ~config ~runtime_factory ~connection =
  if config.Types.Config.server.enable_otel then
    Some
      (Server_metrics.connection
         ~runtime:(runtime_factory ~sw ~connection ())
         ~connection)
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

let h2_client_connection_preface_length = 24

let observe_ingress_security t bytes ~off ~len =
  let off, len =
    if t.security_preface_remaining = 0 then (off, len)
    else
      let skipped = min t.security_preface_remaining len in
      t.security_preface_remaining <- t.security_preface_remaining - skipped;
      (off + skipped, len - skipped)
  in
  if len = 0 then None
  else Eta_http.H2.Security.observe t.security bytes ~off ~len

let frame_header_size = 9

let frame_length s off =
  (Char.code s.[off] lsl 16)
  lor (Char.code s.[off + 1] lsl 8)
  lor Char.code s.[off + 2]

let frame_type s off = Char.code s.[off + 3]

let frame_stream_id s off =
  ((Char.code s.[off + 5] land 0x7f) lsl 24)
  lor (Char.code s.[off + 6] lsl 16)
  lor (Char.code s.[off + 7] lsl 8)
  lor Char.code s.[off + 8]

let client_request_stream_id stream_id = stream_id > 0 && stream_id land 1 = 1

let h2_security_config t =
  Option.value t.config.Types.Config.h2_security_config
    ~default:Eta_http.H2.Security.default_config

let note_headers_frame t stream_id =
  if
    client_request_stream_id stream_id
    && not (Hashtbl.mem t.stream_ordinals stream_id)
  then (
    t.observed_request_ordinal <- t.observed_request_ordinal + 1;
    Hashtbl.add t.stream_ordinals stream_id t.observed_request_ordinal)

let note_remote_reset_frame t stream_id =
  Hashtbl.replace t.remote_reset_streams stream_id ();
  t.filter_rst_stream_seen <- t.filter_rst_stream_seen + 1;
  let security_config = h2_security_config t in
  if
    t.filter_rst_stream_seen
    > security_config.max_rst_stream_per_connection
    && Option.is_none t.filter_error
  then
    t.filter_error <-
      Some
        (Eta_http.Error.Rst_rate_exceeded
           {
             observed_per_second = t.filter_rst_stream_seen;
             limit_per_second =
               security_config.max_rst_stream_per_connection;
           });
  match Hashtbl.find_opt t.stream_ordinals stream_id with
  | None -> ()
  | Some ordinal -> Hashtbl.replace t.remote_reset_ordinals ordinal ()

let filter_ingress t bytes ~off ~len =
  let raw = Bigstringaf.substring bytes ~off ~len in
  let raw_len = String.length raw in
  let output = Buffer.create raw_len in
  let frame_off =
    if t.filter_preface_remaining = 0 then 0
    else
      let prefix_len = min t.filter_preface_remaining raw_len in
      Buffer.add_substring output raw 0 prefix_len;
      t.filter_preface_remaining <- t.filter_preface_remaining - prefix_len;
      prefix_len
  in
  let frames =
    let frame_bytes = String.sub raw frame_off (raw_len - frame_off) in
    if String.equal t.filter_pending "" then frame_bytes
    else t.filter_pending ^ frame_bytes
  in
  t.filter_pending <- "";
  let frames_len = String.length frames in
  let rec loop off =
    if off + frame_header_size > frames_len then
      t.filter_pending <- String.sub frames off (frames_len - off)
    else
      let length = frame_length frames off in
      let total = frame_header_size + length in
      if off + total > frames_len then
        t.filter_pending <- String.sub frames off (frames_len - off)
      else (
        let ty = frame_type frames off in
        let stream_id = frame_stream_id frames off in
        let drop =
          ty = 0x0 && Hashtbl.mem t.remote_reset_streams stream_id
        in
        if ty = 0x1 then note_headers_frame t stream_id
        else if ty = 0x3 then note_remote_reset_frame t stream_id;
        if not drop then Buffer.add_substring output frames off total;
        loop (off + total))
  in
  loop 0;
  match t.filter_error with
  | Some kind -> Error kind
  | None ->
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

let request_of_reqd ~connection ~ordinal ~body reqd =
  let request = H2.Reqd.request reqd in
  let path, query = Server.Request.split_target request.target in
  let headers = H2.Headers.to_list request.headers in
  {
    Server.Request.id = request_id connection.Types.Connection_info.id ordinal;
    version = Eta_http.Core.Version.H2;
    scheme = request.scheme;
    authority = H2.Headers.get request.headers ":authority";
    method_ = method_to_string request.meth;
    target = request.target;
    path;
    query;
    headers = Eta_http.Core.Header.unsafe_of_list headers;
    body;
    trailers = (fun () -> Eta.Effect.pure Eta_http.Core.Header.empty);
    peer = connection.peer;
    tls = connection.tls;
    alpn_protocol = connection.alpn_protocol;
    stream_id = None;
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

let h2_header_list headers =
  headers
  |> Eta_http.Core.Header.to_list
  |> List.map (fun (name, value) ->
         (Eta_http.Core.Header.normalize_name name, value))

let h2_response response =
  H2.Response.create
    ~headers:(H2.Headers.of_list (h2_header_list response.headers))
    (H2.Status.of_code response.status)

let validate_response_headers t response =
  match
    Server.Validation.validate_h2_response_headers
      ~limits:t.config.server.limits
      (Server.Response.headers response)
  with
  | Ok () -> Ok ()
  | Error message -> Error (response_write_error t ~message ())

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
  || Eta_http.Core.Status.is_informational status
  || status = 204 || status = 304

let strict_no_body_status status =
  Eta_http.Core.Status.is_informational status || status = 204 || status = 304

let add_content_length_header length headers =
  Eta_http.Core.Header.unsafe_add "content-length" (string_of_int length) headers

let prepare_h2_response t request response =
  match validate_response_headers t response with
  | Error _ as error -> error
  | Ok () -> (
      let headers = Server.Response.headers response in
      match Eta_http.Core.Header.get "content-length" headers with
      | Some _ ->
          Error
            (response_write_error t
               ~message:"caller supplied HTTP/2 response Content-Length" ())
      | None -> (
          let status = Server.Response.status response in
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
                    | Some length -> add_content_length_header length headers);
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
              Ok { status; headers; body = Response_stream stream }))

let max_h2_data_chunk = 16 * 1024

let write_fixed_chunk writer chunk =
  let len = Bytes.length chunk in
  let rec loop off =
    if off < len then (
      let chunk_len = min max_h2_data_chunk (len - off) in
      H2.Body.Writer.write_string writer (Bytes.sub_string chunk off chunk_len);
      loop (off + chunk_len))
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
  | Response_no_body _ -> H2.Reqd.respond_with_string reqd (h2_response response) ""
  | Response_fixed (chunks, _) ->
      H2.Reqd.respond_with_string reqd (h2_response response)
        (Bytes.unsafe_to_string (Bytes.concat Bytes.empty chunks))
  | Response_stream _ ->
      invalid_arg
        "Eta_http_eio.H2.Server_connection.respond_fixed: streaming body"

let write_iovecs t iovecs =
  if H2.IOVec.lengthv iovecs = 0 then 0
  else
    let write () =
      Eio.Flow.single_write t.flow (Writer.cstructs_of_iovecs iovecs)
    in
    match t.config.server.timeouts.response_write_timeout with
    | None -> write ()
    | Some timeout -> t.with_timeout timeout write

let rec drain_writes t =
  match H2.Server_connection.next_write_operation t.h2 with
  | `Write iovecs ->
      let written = write_iovecs t iovecs in
      H2.Server_connection.report_write_result t.h2 (`Ok written);
      drain_writes t
  | `Yield -> ()
  | `Close _ ->
      H2.Server_connection.report_write_result t.h2 `Closed;
      (try Eio.Flow.shutdown t.flow `Send with _ -> ())

let h2_read_buffer_size config =
  config.Types.Config.h2_config.H2.Config.read_buffer_size

let max_ingress_buffer_size config =
  config.Types.Config.read_buffer_size + h2_read_buffer_size config
  + Eta_http.H2.Frame.header_size

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
        H2.Server_connection.read t.h2 t.ingress_buffer ~off:t.ingress_off
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
    H2.Server_connection.read_eof t.h2 t.ingress_buffer ~off:t.ingress_off
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
  state.request_discarding <- false;
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
  state.response_write_resolver <- None

let close_request_body state =
  state.request_done <- true;
  clear_request_discard state;
  try
    if not (H2.Body.Reader.is_closed state.request_body) then
      H2.Body.Reader.close state.request_body
  with _ -> ()

let forget_stream t ordinal state =
  state.response_writer <- None;
  Hashtbl.remove t.streams ordinal;
  wake_reader t

let forget_if_complete t ordinal state =
  if state.request_done && state.response_done then forget_stream t ordinal state

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
  if state.request_done then (
    clear_request_discard state;
    forget_if_complete t ordinal state;
    resolve_unit resolver)
  else if remaining <= 0 then (
    close_request_body state;
    forget_if_complete t ordinal state;
    resolve_unit resolver)
  else if H2.Body.Reader.is_closed state.request_body then (
    state.request_done <- true;
    clear_request_discard state;
    forget_if_complete t ordinal state;
    resolve_unit resolver)
  else (
    state.request_discarding <- true;
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
            state.request_done <- true;
            clear_request_discard state;
            forget_if_complete t ordinal state;
            resolve_unit resolver
        | Error error ->
            Option.iter (fun resolver -> resolve resolver (Error error)) resolver;
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
            close_request_body state;
            forget_if_complete t ordinal state))

let discard_request_body_with_policy ?resolver ~drain t ordinal state =
  if state.request_done || state.request_discarding then resolve_unit resolver
  else
    match (drain, t.config.server.unread_body_policy) with
    | true, Eta_http.Server.Config.Drain_up_to limit ->
        drain_request_body t ordinal state limit resolver
    | true, Eta_http.Server.Config.Reset | false, _ ->
        close_request_body state;
        forget_if_complete t ordinal state;
        resolve_unit resolver

let finish_response t ordinal state =
  if not state.response_done then Server_stats.H2.stream_completed t.stats;
  finish_stream_metrics state;
  state.response_done <- true;
  discard_request_body_with_policy ~drain:true t ordinal state;
  forget_if_complete t ordinal state

let finish_reset_response t ordinal state =
  finish_stream_metrics state;
  state.response_done <- true;
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
      close_request_body state;
      close_response_writer_best_effort state;
      state.response_done <- true;
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
  close_request_body state;
  close_response_writer_best_effort state;
  state.response_done <- true;
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
  (not state.request_done)
  &&
  try not (H2.Body.Reader.is_closed state.request_body) with _ -> false

let has_open_request_bodies t =
  Hashtbl.fold
    (fun _ordinal state found -> found || request_body_open state)
    t.streams false

let handle_security_error t kind =
  let error = security_error t kind in
  record_protocol_error t;
  mark_closed t;
  fail_active_streams t error;
  close_flow_all t.flow

let finish_graceful_shutdown_if_idle t =
  if t.graceful_shutdown && (not t.closed) && Hashtbl.length t.streams = 0 then (
    mark_closed t;
    drain_writes t;
    try Eio.Flow.shutdown t.flow `Send with _ -> ())

let schedule_request_body_timeout t ordinal resolver timeout =
  Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
      t.sleep timeout;
      ignore (enqueue t (Request_body_timeout (ordinal, resolver)));
      `Stop_daemon)

let arm_request_body_read t ordinal resolver =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> resolve resolver (Error (request_body_closed_error t ordinal))
  | Some state when state.request_done || state.request_discarding ->
      resolve resolver (Ok None)
  | Some state ->
      state.request_read_resolver <- Some resolver;
      Option.iter
        (schedule_request_body_timeout t ordinal resolver)
        t.config.server.timeouts.request_body_timeout;
      H2.Body.Reader.schedule_read state.request_body
        ~on_read:(fun bs ~off ~len ->
          state.request_read_resolver <- None;
          match record_request_body_bytes t state len with
          | Error error ->
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
              state.request_done <- true;
              forget_if_complete t ordinal state;
              resolve resolver (Ok None)
          | Error error ->
              close_request_body state;
              forget_if_complete t ordinal state;
              resolve resolver (Error error))

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
  | Some state when state.response_done ->
      resolve resolver
        (Error
           (response_write_error t ~message:"response already completed" ()));
      `Done
  | Some state -> (
      match response.body with
      | Response_fixed (_, length) when length > max_h2_data_chunk ->
          let writer =
            H2.Reqd.respond_with_streaming state.reqd (h2_response response)
          in
          state.response_writer <- Some writer;
          state.response_write_resolver <- Some resolver;
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
            H2.Reqd.respond_with_streaming state.reqd (h2_response response)
          in
          state.response_writer <- Some writer;
          state.response_write_resolver <- Some resolver;
          discard_request_body_with_policy ~drain:true t ordinal state;
          `Flush (state, resolver))

let write_response_chunk t ordinal chunk resolver =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> resolve resolver (Error (response_write_error t ()))
  | Some { response_writer = None; _ } ->
      resolve resolver
        (Error
           (response_write_error t
              ~message:"response streaming writer has not been started" ()))
  | Some ({ response_writer = Some writer; _ } as state) ->
      if H2.Body.Writer.is_closed writer then
        resolve resolver
          (Error
             (response_write_error t ~message:"response writer is closed" ()))
      else (
        Server_stats.H2.add_response_bytes t.stats (Bytes.length chunk);
        Option.iter
          (fun metrics ->
            Server_metrics.response_body_bytes metrics (Bytes.length chunk))
          state.metrics;
        write_fixed_chunk writer chunk;
        state.response_write_resolver <- Some resolver;
        H2.Body.Writer.flush writer (function
          | `Written ->
              state.response_write_resolver <- None;
              resolve resolver (Ok ())
          | `Closed ->
              state.response_write_resolver <- None;
              resolve resolver
                (Error
                   (response_write_error t ~message:"response flush closed" ()))))

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
              H2.Reqd.schedule_trailers state.reqd
                (H2.Headers.of_list
                   (List.map
                      (fun (name, value) ->
                        (Eta_http.Core.Header.normalize_name name, value))
                      trailers));
            state.response_write_resolver <- Some resolver;
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
          state.response_write_resolver <- Some resolver;
          `Flush (state, resolver))

let fail_response t ordinal error =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> ()
  | Some state ->
      Server_stats.H2.stream_reset t.stats;
      Option.iter
        (fun metrics -> Server_metrics.stream_resets metrics 1)
        state.metrics;
      H2.Reqd.report_exn state.reqd (Failure (Server.Error.to_string error));
      finish_reset_response t ordinal state

let begin_immediate_shutdown t =
  if not t.closed then (
    mark_closed t;
    fail_active_streams t (shutdown_error t);
    close_flow_all t.flow)

let start_shutdown_timer t timeout =
  if not t.shutdown_timer_started then (
    t.shutdown_timer_started <- true;
    Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
        t.sleep timeout;
        ignore (enqueue t (Shutdown Immediate));
        `Stop_daemon))

let begin_graceful_shutdown t timeout =
  if Eta.Duration.is_zero timeout then begin_immediate_shutdown t
  else if not t.closed then (
    t.graceful_shutdown <- true;
    start_shutdown_timer t timeout;
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
      Fun.protect
        ~finally:(fun () -> resolve ack ())
        (fun () ->
          match observe_ingress_security t bytes ~off ~len with
          | Some kind -> handle_security_error t kind
          | None -> (
              match filter_ingress t bytes ~off ~len with
              | Error kind -> handle_security_error t kind
              | Ok None -> drain_writes t
              | Ok (Some (bytes, len)) -> (
                  match append_ingress t bytes ~off:0 ~len with
                  | Error error ->
                      record_protocol_error t;
                      mark_closed t;
                      fail_active_streams t error;
                      close_flow_all t.flow
                  | Ok () ->
                      feed_ingress t;
                      apply_remote_resets t;
                      drain_writes t)))
  | Ingress_eof ->
      read_eof t;
      if has_open_request_bodies t then (
        mark_closed t;
        fail_active_streams t (connection_closed_error t Request_body))
      else if Hashtbl.length t.streams = 0 then mark_closed t;
      drain_writes t
  | Ingress_failed error ->
      mark_closed t;
      fail_active_streams t error;
      close_flow_all t.flow
  | Request_body_read (ordinal, resolver) ->
      arm_request_body_read t ordinal resolver;
      drain_writes t
  | Request_body_timeout (ordinal, resolver) ->
      handle_request_body_timeout t ordinal resolver;
      drain_writes t
  | Request_body_drain_timeout (ordinal, token) ->
      handle_request_body_drain_timeout t ordinal token;
      drain_writes t
  | Request_body_discard (ordinal, drain, resolver) ->
      discard_request_body t ordinal drain resolver;
      drain_writes t
  | Response_start (ordinal, response, resolver) ->
      (match start_response t ordinal response resolver with
      | `Done -> drain_writes t
      | `Flush (state, resolver) ->
          drain_writes t;
          state.response_write_resolver <- None;
          resolve resolver (Ok ()))
  | Response_chunk (ordinal, chunk, resolver) ->
      write_response_chunk t ordinal chunk resolver;
      drain_writes t
  | Response_trailers (ordinal, trailers, resolver) ->
      (match schedule_response_trailers t ordinal trailers resolver with
      | `Done -> drain_writes t
      | `Flush (state, resolver) ->
          drain_writes t;
          state.response_write_resolver <- None;
          resolve resolver (Ok ()))
  | Response_close (ordinal, resolver) ->
      (match close_response_writer t ordinal resolver with
      | `Done -> drain_writes t
      | `Flush (state, resolver) ->
          drain_writes t;
          state.response_write_resolver <- None;
          finish_response t ordinal state;
          resolve resolver (Ok ()))
  | Response_failed (ordinal, error) ->
      fail_response t ordinal error;
      drain_writes t
  | Shutdown policy ->
      begin_shutdown t policy;
      drain_writes t

let rec owner_loop t =
  if (not t.closed) && not (H2.Server_connection.is_closed t.h2) then (
    drain_writes t;
    let command = Eio.Stream.take t.commands in
    handle_command t command;
    finish_graceful_shutdown_if_idle t;
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
    let wakeup = t.reader_wakeup in
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
    Eio.Fiber.first read (fun () ->
        Eio.Promise.await wakeup;
        `Retry)
  in
  let rec loop () =
    match single_read () with
    | `Retry ->
        reset_reader_wakeup t;
        loop ()
    | `Timeout timeout ->
        ignore
          (enqueue t (Ingress_failed (request_timeout_error t (Some timeout))))
    | `Read 0 -> ignore (enqueue t Ingress_eof)
    | `Read len ->
        let owned = Bigstringaf.create len in
        Bigstringaf.blit scratch ~src_off:0 owned ~dst_off:0 ~len;
        let promise, ack = Eio.Promise.create () in
        if enqueue t (Ingress { bytes = owned; off = 0; len; ack }) then (
          Eio.Promise.await promise;
          loop ())
    | exception End_of_file -> ignore (enqueue t Ingress_eof)
    | exception Eio.Cancel.Cancelled _ -> ()
    | exception exn ->
        ignore (enqueue t (Ingress_failed (connection_read_error t exn)))
  in
  loop ()

let fail_owner_loop t error =
  mark_closed t;
  fail_active_streams t error;
  close_flow_all t.flow

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
      Eio.Fiber.first
        (fun () -> Eio.Promise.await promise)
        (fun () ->
          Eio.Promise.await t.closed_signal;
          Error (connection_closed_error t Response_body))
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

let run_handler t ordinal request handler =
  Eio.Fiber.fork ~sw:t.sw (fun () ->
      let rt = t.runtime_factory ~sw:t.sw ~connection:t.connection () in
      let effect = safe_handler_effect t request handler in
      let response =
        match t.config.server.timeouts.handler_timeout with
        | Some timeout -> (
            match t.with_timeout timeout (fun () -> Eta.Runtime.run rt effect) with
            | Eta.Exit.Ok response -> response
            | Eta.Exit.Error cause -> fallback_error_response t request cause
            | exception Eio.Time.Timeout ->
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
            await_owner t (fun resolver ->
                Response_start (ordinal, prepared, resolver))
          with
          | Error error ->
              release_prepared_response_body rt prepared;
              ignore (enqueue t (Response_failed (ordinal, error)))
          | Ok () -> (
              match prepared.body with
              | Response_fixed (chunks, length) when length > max_h2_data_chunk
                ->
                  pump_response_stream t rt ordinal request response
                    (fixed_response_stream chunks length) 0
              | Response_no_body (Some stream) -> release_response_stream rt stream
              | Response_no_body None | Response_fixed _ -> ()
              | Response_stream stream ->
                  pump_response_stream t rt ordinal request response stream 0)))

let shutdown t policy =
  if not t.closed then ignore (enqueue t (Shutdown policy))

let run ~sw ~clock ?time ~flow ~connection ~config ~runtime_factory ?on_start
    ?on_close handler =
  validate_config config;
  let time = Option.value time ~default:(Types.live_time clock) in
  let h2_config = config.Types.Config.h2_config in
  let request_ordinal = ref 0 in
  let holder = ref None in
  let h2 =
    H2.Server_connection.create ~config:h2_config
      ~error_handler:(fun ?request:_ _ respond ->
        Option.iter record_protocol_error !holder;
        let body = respond H2.Headers.empty in
        H2.Body.Writer.close body)
      (fun reqd ->
        match !holder with
        | None ->
            H2.Reqd.report_exn reqd
              (Failure "Eta_http_eio.H2.Server_connection owner not initialized")
        | Some t ->
            t.accepted_request <- true;
            incr request_ordinal;
            let ordinal = !request_ordinal in
            let body = body_of_stream t ordinal in
            let request = request_of_reqd ~connection ~ordinal ~body reqd in
            let metrics =
              request_metrics ~sw:t.sw ~config:t.config
                ~runtime_factory:t.runtime_factory ~connection:t.connection
                request
            in
            Option.iter Server_metrics.request_started metrics;
            Option.iter Server_metrics.stream_started metrics;
            Server_stats.H2.stream_opened t.stats;
            Hashtbl.add t.streams ordinal
              {
                reqd;
                request_body = H2.Reqd.request_body reqd;
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
                request_done = false;
                request_discarding = false;
                request_read_resolver = None;
                request_discard_resolver = None;
                request_discard_timeout_token = None;
                response_writer = None;
                response_write_resolver = None;
                response_done = false;
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
  in
  let security =
    Eta_http.H2.Security.create
      ?config:config.Types.Config.h2_security_config ()
  in
  let closed_signal, close_signal = Eio.Promise.create () in
  let reader_wakeup, reader_wakeup_resolver = Eio.Promise.create () in
  let t =
    let max_ingress_buffer_size = max_ingress_buffer_size config in
    {
      sw;
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
      observed_request_ordinal = 0;
      stream_ordinals = Hashtbl.create 16;
      remote_reset_streams = Hashtbl.create 16;
      remote_reset_ordinals = Hashtbl.create 16;
      filter_rst_stream_seen = 0;
      filter_error = None;
      commands = Eio.Stream.create config.command_queue_capacity;
      streams =
        Hashtbl.create
          (Int32.to_int h2_config.H2.Config.max_concurrent_streams);
      connection;
      config;
      runtime_factory;
      stats = Server_stats.H2.create ();
      connection_metrics =
        connection_metrics ~sw ~config ~runtime_factory ~connection;
      closed_signal;
      close_signal;
      reader_wakeup;
      reader_wakeup_resolver;
      graceful_shutdown = false;
      shutdown_timer_started = false;
      accepted_request = false;
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
      Option.iter
        (fun metrics -> Server_metrics.active_connections metrics 0)
        t.connection_metrics;
      Option.iter
        (fun metrics -> Server_metrics.shutdown_active metrics 0)
        t.connection_metrics;
      H2.Server_connection.shutdown h2;
      close_flow_all flow;
      Option.iter (fun on_close -> on_close (stats t)) on_close)
    (fun () ->
      Eio.Fiber.fork ~sw (fun () -> reader_loop t);
      run_owner_loop t)

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
