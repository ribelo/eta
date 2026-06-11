(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Server = Eta_http.Server
module Types = Server_types

type flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

type stats = {
  active_requests : int;
  completed_requests : int;
  request_bytes : int;
  response_bytes : int;
  protocol_errors : int;
}

type stats_state = {
  mutable active_requests : int;
  mutable completed_requests : int;
  mutable request_bytes : int;
  mutable response_bytes : int;
  mutable protocol_errors : int;
}

type t = {
  sw : Eio.Switch.t;
  flow : flow;
  connection : Types.Connection_info.t;
  config : Types.Config.t;
  runtime_factory : Types.runtime_factory;
  stats_state : stats_state;
  mutable closed : bool;
}

type request_head = {
  method_ : string;
  target : string;
  version : Eta_http.Core.Version.t;
  headers : Eta_http.Core.Header.t;
  body_initial : bytes;
}

type body_source = {
  t : t;
  initial : bytes;
  mutable off : int;
  mutable remaining : int;
  scratch : Cstruct.t;
}

let create_stats_state () =
  {
    active_requests = 0;
    completed_requests = 0;
    request_bytes = 0;
    response_bytes = 0;
    protocol_errors = 0;
  }

let stats t : stats =
  {
    active_requests = t.stats_state.active_requests;
    completed_requests = t.stats_state.completed_requests;
    request_bytes = t.stats_state.request_bytes;
    response_bytes = t.stats_state.response_bytes;
    protocol_errors = t.stats_state.protocol_errors;
  }

let validate_config config =
  if config.Types.Config.read_buffer_size <= 0 then
    invalid_arg
      "Eta_http_eio.H1.Server_connection.run: read_buffer_size must be > 0";
  Eta_http.Server.Config.validate config.server

let error t ?(method_ = "*") ?(target = "*") kind =
  Server.Error.make ~protocol:t.connection.protocol ~method_ ~target kind

let connection_closed_error t during =
  error t (Connection_closed { during })

let request_parse_error t parse_error =
  let message =
    Eta_http.H1.Request_parse.parse_error_to_string parse_error
  in
  error t (Bad_request { message })

let response_write_error t message =
  error t (Response_write_failed { message })

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

let min_positive left right =
  if left <= 0 then right else if right <= 0 then left else min left right

let request_head_capacity config =
  let limits = config.Types.Config.server.Eta_http.Server.Config.limits in
  limits.max_request_line_bytes + limits.max_request_header_bytes + 4

let read_request_head t =
  let limits = t.config.server.limits in
  let capacity = request_head_capacity t.config in
  let buffer = Bytes.create capacity in
  let scratch_len = min_positive t.config.read_buffer_size capacity in
  let scratch = Cstruct.create scratch_len in
  let rec loop used =
    match
      Eta_http.H1.Request_parse.parse buffer ~len:used
        ~max_request_line_bytes:limits.max_request_line_bytes
        ~max_header_bytes:limits.max_request_header_bytes
        ~max_headers:limits.max_request_headers
    with
    | Ok request ->
        let body_len = used - request.body_off in
        let body_initial = Bytes.create body_len in
        if body_len > 0 then
          Bytes.blit buffer request.body_off body_initial 0 body_len;
        let headers =
          Eta_http.Core.Header.unsafe_of_list
            (Eta_http.H1.Request_parse.headers_to_list buffer request.headers)
        in
        Ok
          {
            method_ = Eta_http.H1.Request_parse.method_to_string buffer request;
            target = Eta_http.H1.Request_parse.target_to_string buffer request;
            version = request.version;
            headers;
            body_initial;
          }
    | Error Eta_http.H1.Request_parse.Partial ->
        if used >= capacity then
          Error
            (request_parse_error t
               (Header_section_too_large
                  { limit = limits.max_request_header_bytes }))
        else
          let read_len = min (Cstruct.length scratch) (capacity - used) in
          let read =
            try
              Eio.Flow.single_read t.flow (Cstruct.sub scratch 0 read_len)
            with
            | End_of_file -> 0
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
                raise
                  (Failure
                     ("Eta_http_eio.H1.Server_connection.read: "
                    ^ Printexc.to_string exn))
          in
          if read = 0 then Error (connection_closed_error t Request_headers)
          else (
            Cstruct.blit_to_bytes scratch 0 buffer used read;
            loop (used + read))
    | Error parse_error -> Error (request_parse_error t parse_error)
  in
  loop 0

let source_pending source =
  Bytes.length source.initial - source.off

let source_take_pending source n =
  let take = min n (source_pending source) in
  let chunk = Bytes.sub source.initial source.off take in
  source.off <- source.off + take;
  chunk

let source_read_some source max_len =
  if max_len <= 0 || source.remaining <= 0 then Eta.Effect.pure None
  else if source_pending source > 0 then
    let chunk = source_take_pending source (min max_len source.remaining) in
    source.remaining <- source.remaining - Bytes.length chunk;
    source.t.stats_state.request_bytes <-
      source.t.stats_state.request_bytes + Bytes.length chunk;
    Eta.Effect.pure (Some chunk)
  else
    let len =
      min max_len (min source.remaining (Cstruct.length source.scratch))
    in
    Eta.Effect.sync (fun () ->
        try `Read (Eio.Flow.single_read source.t.flow (Cstruct.sub source.scratch 0 len))
        with
        | End_of_file -> `Eof
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | _ -> `Closed)
    |> Eta.Effect.bind (function
         | `Read 0 | `Eof ->
             Eta.Effect.fail
               (connection_closed_error source.t Request_body)
         | `Closed ->
             Eta.Effect.fail
               (connection_closed_error source.t Request_body)
         | `Read read ->
             let chunk = Bytes.create read in
             Cstruct.blit_to_bytes source.scratch 0 chunk 0 read;
             source.remaining <- source.remaining - read;
             source.t.stats_state.request_bytes <-
               source.t.stats_state.request_bytes + read;
             Eta.Effect.pure (Some chunk))

let rec drain_fixed_body source =
  source_read_some source source.remaining
  |> Eta.Effect.bind (function
       | None -> Eta.Effect.unit
       | Some _ -> drain_fixed_body source)

let fixed_body t initial length =
  let source =
    {
      t;
      initial;
      off = 0;
      remaining = length;
      scratch = Cstruct.create t.config.read_buffer_size;
    }
  in
  Server.Body.of_reader
    ~discard:(fun ~drain ->
      if drain then drain_fixed_body source
      else (
        source.remaining <- 0;
        Eta.Effect.unit))
    (fun () -> source_read_some source source.remaining)

let unsupported_chunked_body t =
  Server.Body.of_reader (fun () ->
      Eta.Effect.fail
        (error t
           (Protocol_error
              {
                kind = "unsupported_request_body";
                message = "chunked request bodies are not wired into H1 server yet";
              })))

let request_body t head =
  match Eta_http.H1.Request_body.of_headers head.headers with
  | Error body_error ->
      Error
        (error t
           (Header_invalid
              { reason = Eta_http.H1.Request_body.error_to_string body_error }))
  | Ok No_body ->
      Ok
        ( Server.Body.empty (),
          fun () -> Eta.Effect.pure Eta_http.Core.Header.empty )
  | Ok (Fixed length) ->
      let limit = t.config.server.limits.max_request_body_bytes in
      (match limit with
      | Some limit when length > limit ->
          Error (error t (Request_body_too_large { limit; length }))
      | None | Some _ ->
          Ok
            ( fixed_body t head.body_initial length,
              fun () -> Eta.Effect.pure Eta_http.Core.Header.empty ))
  | Ok Chunked ->
      Ok
        ( unsupported_chunked_body t,
          fun () -> Eta.Effect.pure Eta_http.Core.Header.empty )

let request_of_head t head ordinal body trailers =
  let path, query = Server.Request.split_target head.target in
  {
    Server.Request.id = t.connection.id ^ "/request-" ^ string_of_int ordinal;
    version = head.version;
    scheme = if t.connection.tls then "https" else "http";
    authority = Eta_http.Core.Header.get "host" head.headers;
    method_ = head.method_;
    target = head.target;
    path;
    query;
    headers = head.headers;
    body;
    trailers;
    peer = t.connection.peer;
    tls = t.connection.tls;
    alpn_protocol = t.connection.alpn_protocol;
    stream_id = None;
    connection_id = t.connection.id;
  }

type response_write_failure = {
  error : Server.Error.t;
  response_started : bool;
}

let response_write_failure ?(response_started = false) error =
  Error { error; response_started }

let write_response_string t wire =
  try
    Eio.Flow.copy_string wire t.flow;
    t.stats_state.response_bytes <-
      t.stats_state.response_bytes + String.length wire;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
      Error
        (response_write_error t
           ("connection write failed: " ^ Printexc.to_string exn))

let response_error_of_cause t cause =
  match find_failure cause with
  | Some error -> error
  | None ->
      response_write_error t
        (Format.asprintf "%a" (Eta.Cause.pp Server.Error.pp) cause)

let write_response_bytes t bytes =
  match write_response_string t (Bytes.to_string bytes) with
  | Ok () -> Ok ()
  | Error error -> response_write_failure ~response_started:true error

let write_response_bytes_list t chunks =
  let rec loop = function
    | [] -> Ok ()
    | chunk :: rest -> (
        match write_response_bytes t chunk with
        | Ok () -> loop rest
        | Error _ as error -> error)
  in
  loop chunks

let release_response_stream rt stream =
  match Eta.Runtime.run rt (stream.Server.Response.Body.release ()) with
  | Eta.Exit.Ok () | Eta.Exit.Error _ -> ()

let with_released_response_stream rt stream f =
  let released = ref false in
  let release_once () =
    if not !released then (
      released := true;
      release_response_stream rt stream)
  in
  Fun.protect ~finally:release_once (fun () ->
      match f () with
      | Ok () ->
          release_once ();
          Ok ()
      | Error _ as error ->
          release_once ();
          error)

let read_response_stream t rt stream =
  match Eta.Runtime.run rt (stream.Server.Response.Body.read ()) with
  | Eta.Exit.Ok chunk -> Ok chunk
  | Eta.Exit.Error cause ->
      response_write_failure ~response_started:true
        (response_error_of_cause t cause)

let response_trailers t rt response =
  match Eta.Runtime.run rt ((Server.Response.trailers response) ()) with
  | Eta.Exit.Ok trailers -> Ok trailers
  | Eta.Exit.Error cause ->
      response_write_failure ~response_started:true
        (response_error_of_cause t cause)

let write_last_chunk t trailers =
  try
    write_response_bytes t
      (Eta_http.H1.Response_write.encode_last_chunk ~trailers ())
  with Invalid_argument message ->
    response_write_failure ~response_started:true
      (response_write_error t message)

let rec pump_fixed_response_stream t rt stream length written =
  match read_response_stream t rt stream with
  | Error _ as error -> error
  | Ok None ->
      if written = length then Ok ()
      else
        response_write_failure ~response_started:true
          (response_write_error t
             "stream ended before declared Content-Length")
  | Ok (Some chunk) ->
      let chunk_length = Bytes.length chunk in
      let next = written + chunk_length in
      if next < written || next > length then
        response_write_failure ~response_started:true
          (response_write_error t
             "stream exceeded declared Content-Length")
      else
        (match write_response_bytes t chunk with
        | Error _ as error -> error
        | Ok () -> pump_fixed_response_stream t rt stream length next)

let rec pump_raw_response_stream t rt stream =
  match read_response_stream t rt stream with
  | Error _ as error -> error
  | Ok None -> Ok ()
  | Ok (Some chunk) -> (
      match write_response_bytes t chunk with
      | Error _ as error -> error
      | Ok () -> pump_raw_response_stream t rt stream)

let rec pump_chunked_response_stream t rt response stream =
  match read_response_stream t rt stream with
  | Error _ as error -> error
  | Ok (Some chunk) -> (
      match
        write_response_bytes_list t
          (Eta_http.H1.Response_write.encode_chunk chunk)
      with
      | Error _ as error -> error
      | Ok () -> pump_chunked_response_stream t rt response stream)
  | Ok None -> (
      match response_trailers t rt response with
      | Error _ as error -> error
      | Ok trailers -> write_last_chunk t trailers)

let write_stream_response t rt response = function
  | Eta_http.H1.Response_write.Stream_fixed stream ->
      with_released_response_stream rt stream (fun () ->
          let length = Option.value stream.length ~default:0 in
          pump_fixed_response_stream t rt stream length 0)
  | Eta_http.H1.Response_write.Stream_chunked stream ->
      with_released_response_stream rt stream (fun () ->
          pump_chunked_response_stream t rt response stream)
  | Eta_http.H1.Response_write.Stream_close_delimited stream ->
      with_released_response_stream rt stream (fun () ->
          pump_raw_response_stream t rt stream)
  | Eta_http.H1.Response_write.No_body | Eta_http.H1.Response_write.Fixed _ ->
      Ok ()

let release_ignored_response_stream rt response =
  match Server.Response.body response with
  | Server.Response.Body.Stream stream -> release_response_stream rt stream
  | Server.Response.Body.Empty | Server.Response.Body.Fixed _ -> ()

let write_response ?rt t request response =
  match
    Eta_http.H1.Response_write.prepare ~version:request.Server.Request.version
      ~request_method:request.method_ response
  with
  | Error error ->
      Option.iter
        (fun rt -> release_ignored_response_stream rt response)
        rt;
      response_write_failure
        (response_write_error t
           (Eta_http.H1.Response_write.error_to_string error))
  | Ok prepared -> (
      match write_response_string t prepared.head with
      | Error error ->
          Option.iter
            (fun rt -> release_ignored_response_stream rt response)
            rt;
          response_write_failure ~response_started:true error
      | Ok () -> (
          match prepared.body with
          | Eta_http.H1.Response_write.No_body ->
              Option.iter
                (fun rt -> release_ignored_response_stream rt response)
                rt;
              Ok ()
          | Eta_http.H1.Response_write.Fixed chunks ->
              write_response_bytes_list t chunks
          | Eta_http.H1.Response_write.Stream_fixed _
          | Eta_http.H1.Response_write.Stream_chunked _
          | Eta_http.H1.Response_write.Stream_close_delimited _ -> (
              match rt with
              | None ->
                  response_write_failure ~response_started:true
                    (response_write_error t
                       "streaming response requires an Eta runtime")
              | Some rt -> write_stream_response t rt response prepared.body)))

let run_handler t request handler =
  let rt = t.runtime_factory ~sw:t.sw ~connection:t.connection () in
  let effect =
    Eta_http.Observability.Server.Tracer.request
      ~enabled:t.config.server.enable_otel
      ~emit_url_full:t.config.server.emit_url_full handler request
  in
  match Eta.Runtime.run rt effect with
  | Eta.Exit.Ok response -> (rt, response)
  | Eta.Exit.Error cause -> (rt, fallback_error_response t request cause)

let write_default_error t request error =
  match write_response t request (Server.Handler.default_error_response error) with
  | Ok () -> ()
  | Error _ -> ()

let run_one_request t handler =
  match read_request_head t with
  | Error error ->
      t.stats_state.protocol_errors <- t.stats_state.protocol_errors + 1;
      let request =
        {
          Server.Request.id = t.connection.id ^ "/request-error";
          version = Eta_http.Core.Version.H1_1;
          scheme = if t.connection.tls then "https" else "http";
          authority = None;
          method_ = "*";
          target = "*";
          path = "*";
          query = None;
          headers = Eta_http.Core.Header.empty;
          body = Server.Body.empty ();
          trailers = (fun () -> Eta.Effect.pure Eta_http.Core.Header.empty);
          peer = t.connection.peer;
          tls = t.connection.tls;
          alpn_protocol = t.connection.alpn_protocol;
          stream_id = None;
          connection_id = t.connection.id;
        }
      in
      write_default_error t request error
  | Ok head -> (
      match request_body t head with
      | Error error ->
          t.stats_state.protocol_errors <- t.stats_state.protocol_errors + 1;
          let request =
            request_of_head t head 1 (Server.Body.empty ())
              (fun () -> Eta.Effect.pure Eta_http.Core.Header.empty)
          in
          write_default_error t request error
      | Ok (body, trailers) ->
          t.stats_state.active_requests <- 1;
          let request = request_of_head t head 1 body trailers in
          let rt, response = run_handler t request handler in
          (match write_response ~rt t request response with
          | Ok () -> ()
          | Error { error; response_started = false } ->
              write_default_error t request error
          | Error { response_started = true; _ } -> ());
          t.stats_state.active_requests <- 0;
          t.stats_state.completed_requests <-
            t.stats_state.completed_requests + 1)

let shutdown t _policy =
  if not t.closed then (
    t.closed <- true;
    try Eio.Flow.shutdown t.flow `All with _ -> ())

let run ~sw ~clock:_ ~flow ~connection ~config ~runtime_factory ?on_start
    ?on_close handler =
  validate_config config;
  let t =
    {
      sw;
      flow;
      connection;
      config;
      runtime_factory;
      stats_state = create_stats_state ();
      closed = false;
    }
  in
  Option.iter (fun on_start -> on_start t) on_start;
  Fun.protect
    ~finally:(fun () ->
      t.closed <- true;
      (try Eio.Flow.shutdown flow `All with _ -> ());
      Option.iter (fun on_close -> on_close (stats t)) on_close)
    (fun () -> run_one_request t handler)
