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

type request_body_read = (bytes option, Server.Error.t) result
type unit_result = (unit, Server.Error.t) result

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
  | Request_body_discard of int * bool * (unit, Server.Error.t) result Eio.Promise.u
  | Response_start of int * Server.Response.t * unit_result Eio.Promise.u
  | Response_chunk of int * bytes * unit_result Eio.Promise.u
  | Response_trailers of int * Eta_http.Core.Header.t * unit_result Eio.Promise.u
  | Response_close of int * unit_result Eio.Promise.u
  | Response_failed of int * Server.Error.t
  | Shutdown of Types.shutdown

type stream_state = {
  reqd : H2.Reqd.t;
  request_body : H2.Body.Reader.t;
  metrics : Server_metrics.t option;
  mutable metrics_finished : bool;
  mutable request_done : bool;
  mutable request_discarding : bool;
  mutable request_read_resolver : request_body_read Eio.Promise.u option;
  mutable response_writer : H2.Body.Writer.t option;
  mutable response_write_resolver : unit_result Eio.Promise.u option;
  mutable response_done : bool;
}

type t = {
  sw : Eio.Switch.t;
  sleep : float -> unit;
  with_timeout : 'a. Eta.Duration.t -> (unit -> 'a) -> 'a;
  flow : flow;
  h2 : H2.Server_connection.t;
  security : Eta_http.H2.Security.t;
  mutable security_preface_remaining : int;
  ingress_buffer : Bigstringaf.t;
  max_ingress_buffer_size : int;
  mutable ingress_off : int;
  mutable ingress_len : int;
  commands : command Eio.Stream.t;
  streams : (int, stream_state) Hashtbl.t;
  connection : Types.Connection_info.t;
  config : Types.Config.t;
  runtime_factory : Types.runtime_factory;
  stats : Server_stats.H2.t;
  connection_metrics : Server_metrics.t option;
  closed_signal : unit Eio.Promise.t;
  close_signal : unit Eio.Promise.u;
  mutable graceful_shutdown : bool;
  mutable shutdown_timer_started : bool;
  mutable closed : bool;
}

let mark_closed t =
  if not t.closed then (
    t.closed <- true;
    ignore (Eio.Promise.try_resolve t.close_signal ()))

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

let validate_config config =
  if config.Types.Config.read_buffer_size <= 0 then
    invalid_arg
      "Eta_http_eio.H2.Server_connection.run: read_buffer_size must be > 0";
  if config.command_queue_capacity <= 0 then
    invalid_arg
      "Eta_http_eio.H2.Server_connection.run: command_queue_capacity must be > 0";
  Eta_http.Server.Config.validate config.server

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

let h2_header_list headers =
  headers
  |> Eta_http.Core.Header.to_list
  |> List.map (fun (name, value) ->
         (Eta_http.Core.Header.normalize_name name, value))

let h2_response response =
  H2.Response.create
    ~headers:(H2.Headers.of_list (h2_header_list (Server.Response.headers response)))
    (H2.Status.of_code (Server.Response.status response))

let fixed_body_length chunks =
  List.fold_left (fun total chunk -> total + Bytes.length chunk) 0 chunks

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

let fixed_response_stream chunks =
  let total = fixed_body_length chunks in
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
    Server.Response.Body.length = Some total;
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
  match Server.Response.body response with
  | Empty -> H2.Reqd.respond_with_string reqd (h2_response response) ""
  | Fixed chunks ->
      H2.Reqd.respond_with_string reqd (h2_response response)
        (Bytes.unsafe_to_string (Bytes.concat Bytes.empty chunks))
  | Stream _ ->
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
  match config.Types.Config.h2_config with
  | Some config -> config.H2.Config.read_buffer_size
  | None -> H2.Config.default.read_buffer_size

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

let fail_pending_response_write state error =
  Option.iter
    (fun resolver -> resolve resolver (Error error))
    state.response_write_resolver;
  state.response_write_resolver <- None

let close_request_body state =
  state.request_done <- true;
  state.request_discarding <- false;
  try
    if not (H2.Body.Reader.is_closed state.request_body) then
      H2.Body.Reader.close state.request_body
  with _ -> ()

let forget_stream t ordinal state =
  state.response_writer <- None;
  Hashtbl.remove t.streams ordinal

let forget_if_complete t ordinal state =
  if state.request_done && state.response_done then forget_stream t ordinal state

let resolve_unit resolver =
  Option.iter (fun resolver -> resolve resolver (Ok ())) resolver

let rec drain_request_body t ordinal state remaining resolver =
  if state.request_done then (
    forget_if_complete t ordinal state;
    resolve_unit resolver)
  else if remaining <= 0 then (
    close_request_body state;
    forget_if_complete t ordinal state;
    resolve_unit resolver)
  else if H2.Body.Reader.is_closed state.request_body then (
    state.request_done <- true;
    state.request_discarding <- false;
    forget_if_complete t ordinal state;
    resolve_unit resolver)
  else (
    state.request_discarding <- true;
    H2.Body.Reader.schedule_read state.request_body
      ~on_eof:(fun () ->
        state.request_done <- true;
        state.request_discarding <- false;
        forget_if_complete t ordinal state;
        resolve_unit resolver)
      ~on_read:(fun _bs ~off:_ ~len ->
        Server_stats.H2.add_request_bytes t.stats len;
        Option.iter
          (fun metrics -> Server_metrics.request_body_bytes metrics len)
          state.metrics;
        drain_request_body t ordinal state (remaining - len) resolver))

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
      fail_pending_response_write state request_error;
      close_request_body state;
      close_response_writer_best_effort state;
      state.response_done <- true;
      forget_stream t ordinal state)
    streams

let handle_security_error t kind =
  let error = security_error t kind in
  record_protocol_error t;
  mark_closed t;
  fail_active_streams t error;
  try Eio.Flow.shutdown t.flow `All with _ -> ()

let finish_graceful_shutdown_if_idle t =
  if t.graceful_shutdown && (not t.closed) && Hashtbl.length t.streams = 0 then (
    mark_closed t;
    drain_writes t;
    try Eio.Flow.shutdown t.flow `Send with _ -> ())

let schedule_request_body_timeout t ordinal resolver timeout =
  Eio.Fiber.fork ~sw:t.sw (fun () ->
      t.sleep (Eta.Duration.to_seconds_float timeout);
      ignore (enqueue t (Request_body_timeout (ordinal, resolver))))

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
          Server_stats.H2.add_request_bytes t.stats len;
          Option.iter
            (fun metrics -> Server_metrics.request_body_bytes metrics len)
            state.metrics;
          let chunk = Bytes.create len in
          Bigstringaf.blit_to_bytes bs ~src_off:off chunk ~dst_off:0 ~len;
          resolve resolver (Ok (Some chunk)))
        ~on_eof:(fun () ->
          state.request_read_resolver <- None;
          state.request_done <- true;
          forget_if_complete t ordinal state;
          resolve resolver (Ok None))

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
      match Server.Response.body response with
      | Fixed chunks when fixed_body_length chunks > max_h2_data_chunk ->
          let writer =
            H2.Reqd.respond_with_streaming state.reqd (h2_response response)
          in
          state.response_writer <- Some writer;
          state.response_write_resolver <- Some resolver;
          discard_request_body_with_policy ~drain:true t ordinal state;
          `Flush (state, resolver)
      | Empty | Fixed _ ->
          (match Server.Response.body response with
          | Empty -> ()
          | Fixed chunks ->
              Server_stats.H2.add_response_bytes t.stats
                (fixed_body_length chunks);
              Option.iter
                (fun metrics ->
                  Server_metrics.response_body_bytes metrics
                    (fixed_body_length chunks))
                state.metrics
          | Stream _ -> assert false);
          respond_fixed state.reqd response;
          finish_response t ordinal state;
          resolve resolver (Ok ());
          `Done
      | Stream _ ->
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
  match Header.validate trailers with
  | Some _ ->
      resolve resolver
        (Error
           (response_write_error t
              ~message:"invalid response trailer header" ()));
      `Done
  | None -> (
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
    try Eio.Flow.shutdown t.flow `All with _ -> ())

let start_shutdown_timer t timeout =
  if not t.shutdown_timer_started then (
    t.shutdown_timer_started <- true;
    Eio.Fiber.fork ~sw:t.sw (fun () ->
        t.sleep (Eta.Duration.to_seconds_float timeout);
        ignore (enqueue t (Shutdown Immediate))))

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
              match append_ingress t bytes ~off ~len with
              | Error error ->
                  record_protocol_error t;
                  mark_closed t;
                  fail_active_streams t error;
                  (try Eio.Flow.shutdown t.flow `All with _ -> ())
              | Ok () ->
                  feed_ingress t;
                  drain_writes t))
  | Ingress_eof ->
      mark_closed t;
      fail_active_streams t (connection_closed_error t Request_body);
      read_eof t;
      drain_writes t
  | Ingress_failed error ->
      mark_closed t;
      fail_active_streams t error;
      (try Eio.Flow.shutdown t.flow `All with _ -> ())
  | Request_body_read (ordinal, resolver) ->
      arm_request_body_read t ordinal resolver;
      drain_writes t
  | Request_body_timeout (ordinal, resolver) ->
      handle_request_body_timeout t ordinal resolver;
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
  let rec loop () =
    match Eio.Flow.single_read t.flow cstruct with
    | 0 -> ignore (enqueue t Ingress_eof)
    | len ->
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
  try Eio.Flow.shutdown t.flow `All with _ -> ()

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

let response_error_of_cause t cause =
  match find_failure cause with
  | Some error -> error
  | None -> response_failure_of_cause t cause

let release_response_stream rt stream =
  match Eta.Runtime.run rt (stream.Server.Response.Body.release ()) with
  | Eta.Exit.Ok () | Eta.Exit.Error _ -> ()

let read_response_stream t rt stream =
  Eio.Fiber.first
    (fun () ->
      `Read (Eta.Runtime.run rt (stream.Server.Response.Body.read ())))
    (fun () ->
      Eio.Promise.await t.closed_signal;
      `Closed)

let fail_stream_response t rt ordinal stream error =
  ignore (enqueue t (Response_failed (ordinal, error)));
  release_response_stream rt stream

let rec pump_response_stream t rt ordinal response stream =
  match read_response_stream t rt stream with
  | `Closed -> release_response_stream rt stream
  | `Read (Eta.Exit.Error cause) ->
      fail_stream_response t rt ordinal stream (response_error_of_cause t cause)
  | `Read (Eta.Exit.Ok (Some chunk)) -> (
      match await_owner t (fun resolver -> Response_chunk (ordinal, chunk, resolver)) with
      | Ok () -> pump_response_stream t rt ordinal response stream
      | Error error -> fail_stream_response t rt ordinal stream error)
  | `Read (Eta.Exit.Ok None) -> (
      let trailers =
        match Eta.Runtime.run rt ((Server.Response.trailers response) ()) with
        | Eta.Exit.Ok trailers -> Ok trailers
        | Error cause -> Error (response_error_of_cause t cause)
      in
      match trailers with
      | Error error -> fail_stream_response t rt ordinal stream error
      | Ok trailers -> (
          match
            await_owner t (fun resolver ->
                Response_trailers (ordinal, trailers, resolver))
          with
          | Error error -> fail_stream_response t rt ordinal stream error
          | Ok () -> (
              match
                await_owner t (fun resolver -> Response_close (ordinal, resolver))
              with
              | Ok () -> release_response_stream rt stream
              | Error error -> fail_stream_response t rt ordinal stream error)))

let run_handler t ordinal request handler =
  Eio.Fiber.fork ~sw:t.sw (fun () ->
      let rt = t.runtime_factory ~sw:t.sw ~connection:t.connection () in
      let effect =
        Eta_http.Observability.Server.Tracer.request
          ~enabled:t.config.server.enable_otel
          ~emit_url_full:t.config.server.emit_url_full
          handler request
      in
      let response =
        match Eta.Runtime.run rt effect with
        | Eta.Exit.Ok response -> response
        | Eta.Exit.Error cause -> fallback_error_response t request cause
      in
      match
        await_owner t (fun resolver -> Response_start (ordinal, response, resolver))
      with
      | Error error -> ignore (enqueue t (Response_failed (ordinal, error)))
      | Ok () -> (
          match Server.Response.body response with
          | Fixed chunks when fixed_body_length chunks > max_h2_data_chunk ->
              pump_response_stream t rt ordinal response
                (fixed_response_stream chunks)
          | Empty | Fixed _ -> ()
          | Stream stream -> pump_response_stream t rt ordinal response stream))

let shutdown t policy =
  if not t.closed then ignore (enqueue t (Shutdown policy))

let run ~sw ~clock ~flow ~connection ~config ~runtime_factory ?on_start
    ?on_close handler =
  validate_config config;
  let request_ordinal = ref 0 in
  let holder = ref None in
  let h2 =
    H2.Server_connection.create ?config:config.Types.Config.h2_config
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
                metrics;
                metrics_finished = false;
                request_done = false;
                request_discarding = false;
                request_read_resolver = None;
                response_writer = None;
                response_write_resolver = None;
                response_done = false;
              };
            run_handler t ordinal request handler)
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
      sleep = Eio.Time.sleep clock;
      with_timeout =
        (fun timeout f ->
          Eio.Time.with_timeout_exn clock
            (Eta.Duration.to_seconds_float timeout)
            f);
      flow;
      h2;
      security;
      security_preface_remaining = h2_client_connection_preface_length;
      ingress_buffer = Bigstringaf.create max_ingress_buffer_size;
      max_ingress_buffer_size;
      ingress_off = 0;
      ingress_len = 0;
      commands = Eio.Stream.create config.command_queue_capacity;
      streams = Hashtbl.create config.max_concurrent_streams;
      connection;
      config;
      runtime_factory;
      stats = Server_stats.H2.create ();
      connection_metrics =
        connection_metrics ~sw ~config ~runtime_factory ~connection;
      closed_signal;
      close_signal;
      graceful_shutdown = false;
      shutdown_timer_started = false;
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
      (try Eio.Flow.shutdown flow `All with _ -> ());
      Option.iter (fun on_close -> on_close (stats t)) on_close)
    (fun () ->
      Eio.Fiber.fork ~sw (fun () -> reader_loop t);
      run_owner_loop t)

let run_h2c ~sw ~clock ~flow ~peer ~config ~runtime_factory ?on_start
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
  run ~sw ~clock ~flow ~connection ~config ~runtime_factory ?on_start
    ?on_close handler
