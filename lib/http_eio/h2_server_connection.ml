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
  mutable request_done : bool;
  mutable request_discarding : bool;
  mutable request_read_resolver : request_body_read Eio.Promise.u option;
  mutable response_writer : H2.Body.Writer.t option;
  mutable response_done : bool;
}

type t = {
  sw : Eio.Switch.t;
  sleep : float -> unit;
  flow : flow;
  h2 : H2.Server_connection.t;
  commands : command Eio.Stream.t;
  streams : (int, stream_state) Hashtbl.t;
  connection : Types.Connection_info.t;
  config : Types.Config.t;
  runtime_factory : Types.runtime_factory;
  stats : Server_stats.H2.t;
  mutable graceful_shutdown : bool;
  mutable shutdown_timer_started : bool;
  mutable closed : bool;
}

let stats t =
  Server_stats.H2.snapshot t.stats
    ~active_streams:(Hashtbl.length t.streams)

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

let h2_response response =
  H2.Response.create
    ~headers:
      (H2.Headers.of_list
         (Eta_http.Core.Header.to_list (Server.Response.headers response)))
    (H2.Status.of_code (Server.Response.status response))

let fixed_body_string chunks =
  Bytes.unsafe_to_string (Bytes.concat Bytes.empty chunks)

let fixed_body_length chunks =
  List.fold_left (fun total chunk -> total + Bytes.length chunk) 0 chunks

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
        (fixed_body_string chunks)
  | Stream _ ->
      invalid_arg
        "Eta_http_eio.H2.Server_connection.respond_fixed: streaming body"

let write_iovecs flow iovecs =
  if H2.IOVec.lengthv iovecs = 0 then 0
  else Eio.Flow.single_write flow (Writer.cstructs_of_iovecs iovecs)

let rec drain_writes flow h2 =
  match H2.Server_connection.next_write_operation h2 with
  | `Write iovecs ->
      let written = write_iovecs flow iovecs in
      H2.Server_connection.report_write_result h2 (`Ok written);
      drain_writes flow h2
  | `Yield -> ()
  | `Close _ ->
      H2.Server_connection.report_write_result h2 `Closed;
      (try Eio.Flow.shutdown flow `Send with _ -> ())

let feed h2 buffer ~off ~len =
  let rec loop off len =
    if len > 0 then (
      let consumed = H2.Server_connection.read h2 buffer ~off ~len in
      if consumed <= 0 then
        invalid_arg "Eta_http_eio.H2.Server_connection.feed: h2 consumed no bytes";
      loop (off + consumed) (len - consumed))
  in
  loop off len

let read_eof h2 =
  let empty = Bigstringaf.create 0 in
  ignore (H2.Server_connection.read_eof h2 empty ~off:0 ~len:0 : int)

let fail_pending_request_read state error =
  Option.iter
    (fun resolver -> resolve resolver (Error error))
    state.request_read_resolver;
  state.request_read_resolver <- None

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
  state.response_done <- true;
  discard_request_body_with_policy ~drain:true t ordinal state;
  forget_if_complete t ordinal state

let finish_reset_response t ordinal state =
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
      fail_pending_request_read state request_error;
      close_request_body state;
      close_response_writer_best_effort state;
      state.response_done <- true;
      forget_stream t ordinal state)
    streams

let finish_graceful_shutdown_if_idle t =
  if t.graceful_shutdown && (not t.closed) && Hashtbl.length t.streams = 0 then (
    t.closed <- true;
    drain_writes t.flow t.h2;
    try Eio.Flow.shutdown t.flow `Send with _ -> ())

let arm_request_body_read t ordinal resolver =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> resolve resolver (Error (request_body_closed_error t ordinal))
  | Some state when state.request_done || state.request_discarding ->
      resolve resolver (Ok None)
  | Some state ->
      state.request_read_resolver <- Some resolver;
      H2.Body.Reader.schedule_read state.request_body
        ~on_read:(fun bs ~off ~len ->
          state.request_read_resolver <- None;
          Server_stats.H2.add_request_bytes t.stats len;
          let chunk = Bytes.create len in
          Bigstringaf.blit_to_bytes bs ~src_off:off chunk ~dst_off:0 ~len;
          resolve resolver (Ok (Some chunk)))
        ~on_eof:(fun () ->
          state.request_read_resolver <- None;
          state.request_done <- true;
          forget_if_complete t ordinal state;
          resolve resolver (Ok None))

let discard_request_body t ordinal _drain resolver =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> resolve resolver (Ok ())
  | Some state ->
      discard_request_body_with_policy ?resolver:(Some resolver) ~drain:_drain t
        ordinal state

let start_response t ordinal response resolver =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> resolve resolver (Error (response_write_error t ()))
  | Some state when state.response_done ->
      resolve resolver
        (Error (response_write_error t ~message:"response already completed" ()))
  | Some state -> (
      match Server.Response.body response with
      | Empty | Fixed _ ->
          (match Server.Response.body response with
          | Empty -> ()
          | Fixed chunks ->
              Server_stats.H2.add_response_bytes t.stats
                (fixed_body_length chunks)
          | Stream _ -> assert false);
          respond_fixed state.reqd response;
          finish_response t ordinal state;
          resolve resolver (Ok ())
      | Stream _ ->
          let writer =
            H2.Reqd.respond_with_streaming state.reqd (h2_response response)
          in
          state.response_writer <- Some writer;
          discard_request_body_with_policy ~drain:true t ordinal state;
          resolve resolver (Ok ()))

let write_response_chunk t ordinal chunk resolver =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> resolve resolver (Error (response_write_error t ()))
  | Some { response_writer = None; _ } ->
      resolve resolver
        (Error
           (response_write_error t
              ~message:"response streaming writer has not been started" ()))
  | Some { response_writer = Some writer; _ } ->
      if H2.Body.Writer.is_closed writer then
        resolve resolver
          (Error
             (response_write_error t ~message:"response writer is closed" ()))
      else (
        Server_stats.H2.add_response_bytes t.stats (Bytes.length chunk);
        H2.Body.Writer.write_string writer (Bytes.unsafe_to_string chunk);
        H2.Body.Writer.flush writer (function
          | `Written -> resolve resolver (Ok ())
          | `Closed ->
              resolve resolver
                (Error
                   (response_write_error t ~message:"response flush closed" ()))))

let schedule_response_trailers t ordinal trailers resolver =
  match Header.validate trailers with
  | Some _ ->
      resolve resolver
        (Error
           (response_write_error t
              ~message:"invalid response trailer header" ()))
  | None -> (
      match Hashtbl.find_opt t.streams ordinal with
      | None -> resolve resolver (Error (response_write_error t ()))
      | Some state -> (
          try
            if not (List.is_empty trailers) then
              H2.Reqd.schedule_trailers state.reqd (H2.Headers.of_list trailers);
            resolve resolver (Ok ())
          with exn ->
            resolve resolver
              (Error
                 (response_write_error t ~message:(Printexc.to_string exn) ()))))

let close_response_writer t ordinal resolver =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> resolve resolver (Error (response_write_error t ()))
  | Some { response_writer = None; _ } ->
      resolve resolver
        (Error
           (response_write_error t
              ~message:"response streaming writer has not been started" ()))
  | Some state -> (
      match state.response_writer with
      | None -> assert false
      | Some writer ->
          (try
             if not (H2.Body.Writer.is_closed writer) then
               H2.Body.Writer.close writer
           with _ -> ());
          finish_response t ordinal state;
          resolve resolver (Ok ()))

let fail_response t ordinal error =
  match Hashtbl.find_opt t.streams ordinal with
  | None -> ()
  | Some state ->
      Server_stats.H2.stream_reset t.stats;
      H2.Reqd.report_exn state.reqd (Failure (Server.Error.to_string error));
      finish_reset_response t ordinal state

let begin_immediate_shutdown t =
  if not t.closed then (
    t.closed <- true;
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
  | Types.Immediate -> begin_immediate_shutdown t
  | Types.Graceful timeout -> begin_graceful_shutdown t timeout

let handle_command t = function
  | Ingress { bytes; off; len; ack } ->
      Fun.protect
        ~finally:(fun () -> resolve ack ())
        (fun () ->
          feed t.h2 bytes ~off ~len;
          drain_writes t.flow t.h2)
  | Ingress_eof ->
      t.closed <- true;
      fail_active_streams t (connection_closed_error t Request_body);
      read_eof t.h2;
      drain_writes t.flow t.h2
  | Ingress_failed error ->
      t.closed <- true;
      fail_active_streams t error;
      (try Eio.Flow.shutdown t.flow `All with _ -> ())
  | Request_body_read (ordinal, resolver) ->
      arm_request_body_read t ordinal resolver;
      drain_writes t.flow t.h2
  | Request_body_discard (ordinal, drain, resolver) ->
      discard_request_body t ordinal drain resolver;
      drain_writes t.flow t.h2
  | Response_start (ordinal, response, resolver) ->
      start_response t ordinal response resolver;
      drain_writes t.flow t.h2
  | Response_chunk (ordinal, chunk, resolver) ->
      write_response_chunk t ordinal chunk resolver;
      drain_writes t.flow t.h2
  | Response_trailers (ordinal, trailers, resolver) ->
      schedule_response_trailers t ordinal trailers resolver;
      drain_writes t.flow t.h2
  | Response_close (ordinal, resolver) ->
      close_response_writer t ordinal resolver;
      drain_writes t.flow t.h2
  | Response_failed (ordinal, error) ->
      fail_response t ordinal error;
      drain_writes t.flow t.h2
  | Shutdown policy ->
      begin_shutdown t policy;
      drain_writes t.flow t.h2

let rec owner_loop t =
  if (not t.closed) && not (H2.Server_connection.is_closed t.h2) then (
    drain_writes t.flow t.h2;
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
  t.closed <- true;
  fail_active_streams t error;
  try Eio.Flow.shutdown t.flow `All with _ -> ()

let run_owner_loop t =
  try owner_loop t
  with
  | Eio.Cancel.Cancelled _ -> fail_owner_loop t (shutdown_error t)
  | exn -> fail_owner_loop t (connection_write_error t exn)

let await_owner t make =
  if t.closed then Error (connection_closed_error t Response_body)
  else
    let promise, resolver = Eio.Promise.create () in
    if enqueue t (make resolver) then Eio.Promise.await promise
    else Error (connection_closed_error t Response_body)

let response_error_of_cause t cause =
  match find_failure cause with
  | Some error -> error
  | None -> response_failure_of_cause t cause

let release_response_stream rt stream =
  match Eta.Runtime.run rt (stream.Server.Response.Body.release ()) with
  | Eta.Exit.Ok () | Eta.Exit.Error _ -> ()

let fail_stream_response t rt ordinal stream error =
  ignore (enqueue t (Response_failed (ordinal, error)));
  release_response_stream rt stream

let rec pump_response_stream t rt ordinal response stream =
  match Eta.Runtime.run rt (stream.Server.Response.Body.read ()) with
  | Eta.Exit.Error cause ->
      fail_stream_response t rt ordinal stream (response_error_of_cause t cause)
  | Eta.Exit.Ok (Some chunk) -> (
      match await_owner t (fun resolver -> Response_chunk (ordinal, chunk, resolver)) with
      | Ok () -> pump_response_stream t rt ordinal response stream
      | Error error -> fail_stream_response t rt ordinal stream error)
  | Eta.Exit.Ok None -> (
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
        Option.iter
          (fun t -> Server_stats.H2.protocol_error t.stats)
          !holder;
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
            Server_stats.H2.stream_opened t.stats;
            Hashtbl.add t.streams ordinal
              {
                reqd;
                request_body = H2.Reqd.request_body reqd;
                request_done = false;
                request_discarding = false;
                request_read_resolver = None;
                response_writer = None;
                response_done = false;
              };
            run_handler t ordinal request handler)
  in
  let t =
    {
      sw;
      sleep = Eio.Time.sleep clock;
      flow;
      h2;
      commands = Eio.Stream.create config.command_queue_capacity;
      streams = Hashtbl.create config.max_concurrent_streams;
      connection;
      config;
      runtime_factory;
      stats = Server_stats.H2.create ();
      graceful_shutdown = false;
      shutdown_timer_started = false;
      closed = false;
    }
  in
  holder := Some t;
  Option.iter (fun on_start -> on_start t) on_start;
  Fun.protect
    ~finally:(fun () ->
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
