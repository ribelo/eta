(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Body = Stream
module Body_source = Source
module Connect = Connect
module Dispatch = Dispatch
module Error = Error
module Header = Header
module Url = Url
module H2_proto = H2

type protocol = H1 | H2 | Auto

type stats = {
  protocol : protocol;
  active : int;
  idle : int;
  capacity : int;
  opened : int;
  released : int;
}

type t = {
  protocol : protocol;
  request_impl : Request.t -> (Response.t, Error.t) Eta.Effect.t;
  stats_impl : unit -> (stats, Error.t) Eta.Effect.t;
  shutdown_impl : unit -> (unit, Error.t) Eta.Effect.t;
}

let protocol_to_string = function H1 -> "h1" | H2 -> "h2" | Auto -> "auto"
let default_max_response_body_bytes =
  H1_client.default_max_response_body_bytes

let protocol t = t.protocol
let stats t = t.stats_impl ()
let shutdown t = t.shutdown_impl ()
let request t req = t.request_impl req
let request_with_retry ?policy t req = Retry.run ?policy t.request_impl req


module H1 = struct
  let body = function
    | Request.Empty -> H1_client.Empty
    | Fixed chunks -> H1_client.Fixed chunks
    | Stream body -> H1_client.Stream body
    | Rewindable_stream { length; make } ->
        H1_client.Rewindable_stream { length; make }

  let request_of_request request =
    match
      try Ok (Request.url request) with Invalid_argument message -> Error message
    with
    | Ok url ->
        Ok
          {
            H1_client.method_ = request.Request.method_;
            url;
            headers = request.headers;
            body = body request.body;
          }
    | Error message ->
        Error
          (Error.make ~method_:request.method_ ~uri:request.uri
             (Connection_protocol_violation { kind = "url"; message }))

  let response (response : H1_client.response) =
    Response.make ~status:response.H1_client.status
      ~headers:response.headers ~trailers:response.trailers ~body:response.body ()
end

let request_url request =
  match
    try Ok (Request.url request) with Invalid_argument message -> Error message
  with
  | Ok url -> Ok url
  | Error message ->
      Error
        (Error.make ~method_:request.Request.method_ ~uri:request.uri
           (Connection_protocol_violation { kind = "url"; message }))

let unsupported_alpn request protocol =
  Error.make ~protocol:Error.Unknown ~method_:request.Request.method_
    ~uri:request.uri
    (Tls_handshake_error
       {
         stage = Alpn_negotiation;
         message = "unsupported ALPN protocol " ^ protocol;
       })

let dispatch_alpn ~close ~use_h1 ~use_h2 request alpn =
  match Dispatch.decide_alpn alpn with
  | Error protocol ->
      close ()
      |> Eta.Effect.bind (fun () ->
             Eta.Effect.fail (unsupported_alpn request protocol))
  | Ok Dispatch.Use_h1 -> use_h1 ()
  | Ok Dispatch.Use_h2 -> use_h2 ()

module H2 = struct
  let error request kind =
    Error.make ~protocol:Error.H2 ~method_:request.Request.method_ ~uri:request.uri
      kind

  let protocol_violation request kind message =
    error request (Connection_protocol_violation { kind; message })

  let closed request during = error request (Connection_closed { during })

  let pp_client_error = function
    | `Malformed_response message -> "malformed_response:" ^ message
    | `Invalid_response_body_length _ -> "invalid_response_body_length"
    | `Protocol_error (code, message) ->
        Format.asprintf "protocol_error:%a:%s" H2_proto.Error_code.pp_hum code message
    | `Exn exn -> "exn:" ^ Printexc.to_string exn

  let skip_header name =
    match Header.normalize_name name with
    | "connection" | "host" | "keep-alive" | "proxy-connection"
    | "transfer-encoding" | "upgrade" ->
        true
    | normalized -> String.length normalized > 0 && Char.equal normalized.[0] ':'

  let headers request url =
    match Header.validate request.Request.headers with
    | Some kind -> Error (error request kind)
    | None ->
        let user_headers =
          request.Request.headers
          |> List.filter_map (fun (name, value) ->
                 if skip_header name then None
                 else Some (Header.normalize_name name, value))
        in
        let has_content_length =
          List.exists
            (fun (name, _) -> String.equal (Header.normalize_name name) "content-length")
            user_headers
        in
        let content_length =
          if has_content_length then None
          else
            match request.body with
            | Empty | Stream _ -> None
            | Fixed chunks ->
                Some
                  (chunks
                  |> List.fold_left
                       (fun total chunk -> total + Bytes.length chunk)
                       0)
            | Rewindable_stream { length; _ } -> length
        in
        let user_headers =
          match content_length with
          | None -> user_headers
          | Some length -> ("content-length", string_of_int length) :: user_headers
        in
        Ok (H2_proto.Headers.of_list ((":authority", Url.authority url) :: user_headers))

  let method_ = function
    | `GET -> `GET
    | `HEAD -> `HEAD
    | `POST -> `POST
    | `PUT -> `PUT
    | `DELETE -> `DELETE
    | `CONNECT -> `CONNECT
    | `OPTIONS -> `OPTIONS
    | `TRACE -> `TRACE
    | `PATCH -> `Other "PATCH"
    | `Other method_ -> `Other method_

  let request_of_request request url =
    match headers request url with
    | Error _ as error -> error
    | Ok headers ->
        Ok
          (H2_proto.Request.create
             ~scheme:(Url.scheme_to_string (Url.scheme url))
             ~headers
             (method_ (Request.method_value request))
             (Url.origin_form url))

  let write_chunk writer chunk =
    let chunk = Bytes.to_string chunk in
    let rec loop off =
      if off >= String.length chunk then Eta.Effect.unit
      else
        let len = min 16_384 (String.length chunk - off) in
        Eta.Effect.sync (fun () ->
            H2_proto.Body.Writer.write_string writer (String.sub chunk off len))
        |> Eta.Effect.bind (fun () -> loop (off + len))
    in
    loop 0

  let flush_body_writer writer =
    let promise, resolver = Eio.Promise.create () in
    H2_proto.Body.Writer.flush writer (fun result ->
        ignore (Eio.Promise.try_resolve resolver result));
    Eio.Promise.await promise

  let write_fixed_body_sync writer chunks =
    let write_chunk chunk =
      let s = Bytes.unsafe_to_string chunk in
      let len = Bytes.length chunk in
      let rec loop off =
        if off < len then (
          let write_len = min 65_536 (len - off) in
          H2_proto.Body.Writer.write_string writer s ~off ~len:write_len;
          match flush_body_writer writer with
          | `Written -> loop (off + write_len)
          | `Closed -> ())
      in
      loop 0
    in
    List.iter write_chunk chunks;
    H2_proto.Body.Writer.close writer

  let rec write_stream writer body =
    Body.read body
    |> Eta.Effect.bind (function
         | None -> Eta.Effect.unit
         | Some chunk ->
             write_chunk writer chunk
             |> Eta.Effect.bind (fun () -> write_stream writer body))

  let write_body writer request_body upload =
    match upload with
    | Some { Body_source.stream; _ } -> write_stream writer stream
    | None -> (
        match request_body with
        | Request.Empty -> Eta.Effect.unit
        | Fixed chunks ->
            chunks |> List.map (write_chunk writer) |> Eta.Effect.concat
        | Stream _ | Rewindable_stream _ -> Eta.Effect.unit)

  let close_request_body writer =
    Eta.Effect.sync (fun () -> try H2_proto.Body.Writer.close writer with _ -> ())

  let response_headers response =
    H2_proto.Headers.to_list response.H2_proto.Response.headers
    |> List.filter (fun (name, _) ->
           String.length name = 0 || not (Char.equal name.[0] ':'))

  let response_has_body request status =
    (not (String.equal (String.uppercase_ascii request.Request.method_) "HEAD"))
    && (status < 100 || status >= 200)
    && status <> 204 && status <> 304

  let trailer_result request =
    let promise, resolver = Eio.Promise.create () in
    let resolver_ref = ref (Some resolver) in
    let resolve value =
      match !resolver_ref with
      | None -> ()
      | Some resolver ->
          resolver_ref := None;
          Eio.Promise.resolve resolver value
    in
    let resolve_headers headers =
      match Security.validate_headers headers with
      | Some kind -> resolve (Error (error request kind))
      | None -> resolve (Ok headers)
    in
    let resolve_empty () = resolve (Ok Header.empty) in
    let resolve_error error = resolve (Error error) in
    let trailers () =
      Eta.Effect.sync (fun () -> Eio.Promise.await promise)
      |> Eta.Effect.bind (function
           | Ok headers -> Eta.Effect.pure headers
           | Error error -> Eta.Effect.fail error)
    in
    (trailers, resolve_headers, resolve_empty, resolve_error)

  let informational_status status =
    status >= 100 && status < 200 && status <> 101

  let request_on_connection connection request url =
    let mux = Connection.mux connection in
    let result, resolver = Eio.Promise.create () in
    let body_error = ref None in
    let response_started = ref false in
    let response_returned = ref false in
    let body_wake = ref (fun () -> ()) in
    let unregister_failure = ref (fun () -> ()) in
    let trailers, resolve_trailers, resolve_empty_trailers, resolve_trailer_error =
      trailer_result request
    in
    let unregister () =
      let f = !unregister_failure in
      unregister_failure := (fun () -> ());
      f ()
    in
    let resolve_result value = ignore (Eio.Promise.try_resolve resolver value) in
    let resolve_error error =
      unregister ();
      resolve_result (Error error)
    in
    let set_body_error error =
      body_error := Some error;
      resolve_trailer_error error;
      !body_wake ()
    in
    unregister_failure :=
      Connection.register_failure_handler connection (fun kind ->
          let error = error request kind in
          if !response_started then set_body_error error else resolve_error error);
    let close_no_body stream body =
      resolve_empty_trailers ();
      H2_proto.Body.Reader.close body;
      Multiplexer.mark_complete mux stream;
      ignore (Multiplexer.release mux stream);
      unregister ()
    in
    let response_body stream body =
      let body, wake =
        Multiplexer.body_stream_async
          ~closed_error:(closed request Http_response)
          ~poll_error:(fun () -> !body_error)
          ~on_eof:(fun () ->
            unregister ();
            resolve_empty_trailers ())
          ~on_release:(fun decision ->
            unregister ();
            resolve_trailer_error (closed request Http_response);
            Eta.Effect.sync (fun () ->
                match decision with
                | Stream_state.Queue_rst -> Connection.shutdown connection
                | Stream_state.No_rst -> ()))
          mux stream body
      in
      body_wake := wake;
      body
    in
    let note_upload_error error =
      if !response_started then set_body_error error else resolve_error error
    in
    let open_request h2_request =
      Connection.request connection ~tag:0 h2_request
        ~trailers_handler:(fun headers -> resolve_trailers (H2_proto.Headers.to_list headers))
        ~error_handler:(fun stream error ->
          Multiplexer.mark_remote_reset mux
            (Stream_state.id stream);
          let error =
            protocol_violation request "stream" (pp_client_error error)
          in
          if !response_started then set_body_error error else resolve_error error)
        ~response_handler:(fun stream response body ->
          let status = H2_proto.Status.to_code response.H2_proto.Response.status in
          let headers = response_headers response in
          match Security.validate_headers headers with
          | Some kind ->
              H2_proto.Body.Reader.close body;
              ignore (Multiplexer.release mux stream);
              resolve_error (error request kind)
          | None when informational_status status -> ()
          | None when response_has_body request status ->
              response_started := true;
              let body = response_body stream body in
              let response = Response.make ~status ~headers ~trailers ~body () in
              resolve_result (Ok response)
          | None ->
              response_started := true;
              let response =
                Response.make ~status ~headers ~trailers ~body:(Body.empty ()) ()
              in
              resolve_result (Ok response);
              close_no_body stream body)
    in
    let wait_for_response () =
      Eta.Effect.sync (fun () -> Eio.Promise.await result)
      |> Eta.Effect.bind (function
           | Ok response ->
               response_returned := true;
               Eta.Effect.pure response
           | Error error -> Eta.Effect.fail error)
    in
    match request_of_request request url with
    | Error error -> resolve_error error; Eta.Effect.fail error
    | Ok h2_request -> (
    match open_request h2_request with
    | Error (Admission_rejected { limit }) ->
        let error = error request (Stream_admission_rejected { limit }) in
        resolve_error error;
        Eta.Effect.fail error
    | Error Connection_closed ->
        let error = closed request Http_request in
        resolve_error error;
        Eta.Effect.fail error
    | Error (Request_failed message) ->
        let error = protocol_violation request "request" message in
        resolve_error error;
        Eta.Effect.fail error
    | Ok opened ->
        let release_unreturned_request () =
          if !response_returned then Eta.Effect.unit
          else
            Eta.Effect.sync (fun () ->
                unregister ();
                (try H2_proto.Body.Writer.close opened.request_body with _ -> ());
                match Multiplexer.release mux opened.stream with
                | Stream_state.Queue_rst -> Connection.shutdown connection
                | Stream_state.No_rst -> ())
        in
        Body_source.with_owned_stream (Request.body_source request.body) (fun upload ->
            let write_request =
              write_body opened.request_body request.body upload
              |> Eta.Effect.bind (fun () -> close_request_body opened.request_body)
              |> Eta.Effect.catch (fun error ->
                     if not !response_started then resolve_error error;
                     Eta.Effect.fail error)
            in
            let response_or_writer =
              match request.body with
              | Empty ->
                  close_request_body opened.request_body
                  |> Eta.Effect.bind (fun () -> wait_for_response ())
              | Fixed [] ->
                  close_request_body opened.request_body
                  |> Eta.Effect.bind (fun () -> wait_for_response ())
              | Fixed chunks ->
                  Eta.Effect.sync (fun () ->
                      Connection.fork_daemon connection (fun () ->
                          try write_fixed_body_sync opened.request_body chunks
                          with exn ->
                            let error =
                              protocol_violation request "request_body"
                                (Printexc.to_string exn)
                            in
                            note_upload_error error))
                  |> Eta.Effect.bind (fun () -> wait_for_response ())
              | Stream _ | Rewindable_stream _ ->
                  Eta.Effect.race
                    [
                      wait_for_response ();
                      write_request |> Eta.Effect.bind (fun () -> wait_for_response ());
                    ]
            in
            match request.body with
            | Fixed _ -> response_or_writer
            | Empty | Stream _ | Rewindable_stream _ ->
                Eta.Effect.scoped
                  (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
                     ~release:(fun () -> close_request_body opened.request_body)
                  |> Eta.Effect.bind (fun () -> response_or_writer)))
        |> fun request_effect ->
        Eta.Effect.scoped
          (Eta.Effect.acquire_release ~acquire:Eta.Effect.unit
             ~release:release_unreturned_request
          |> Eta.Effect.bind (fun () -> request_effect)))
end

let make_h1 ~sw ~net
    ?(max_response_body_bytes = default_max_response_body_bytes) ?ca_file () =
  if max_response_body_bytes < 0 then
    invalid_arg "Eta_http.Client.make_h1: max_response_body_bytes must be >= 0";
  let pools = Hashtbl.create 8 in
  let pool_values () = Hashtbl.fold (fun _ pool acc -> pool :: acc) pools [] in
  let pool_for request =
    let key = H1_client.origin_key request.H1_client.url in
    match Hashtbl.find_opt pools key with
    | Some pool -> Eta.Effect.pure pool
    | None ->
        H1_client.make_pool ~max_response_body_bytes ?ca_file ~sw ~net
          request.url
        |> Eta.Effect.map (fun pool ->
               Hashtbl.replace pools key pool;
               pool)
  in
  let request_impl request =
    match H1.request_of_request request with
    | Error error -> Eta.Effect.fail error
    | Ok request ->
        pool_for request
        |> Eta.Effect.bind (fun pool ->
               H1_client.request_with_pool pool request)
        |> Eta.Effect.map H1.response
  in
  let stats_impl () =
    Eta.Effect.sync (fun () ->
        pool_values ()
        |> List.fold_left
             (fun acc pool ->
               let stats = H1_client.pool_stats pool in
               {
                 protocol = H1;
                 active = acc.active + stats.Eta.Pool.active;
                 idle = acc.idle + stats.idle;
                 capacity = acc.capacity + stats.max_size;
                 opened = acc.opened + stats.opened;
                 released = acc.released + stats.closed;
               })
             {
               protocol = H1;
               active = 0;
               idle = 0;
               capacity = 0;
               opened = 0;
               released = 0;
             })
  in
  let shutdown_impl () =
    pool_values () |> List.map H1_client.shutdown_pool |> Eta.Effect.concat
  in
  { protocol = H1; request_impl; stats_impl; shutdown_impl }

let make_h1_direct ~sw ~net ?host_eio
    ?(max_response_body_bytes = default_max_response_body_bytes) ?ca_file () =
  if max_response_body_bytes < 0 then
    invalid_arg
      "Eta_http.Client.make_h1_direct: max_response_body_bytes must be >= 0";
  let request_impl request =
    match H1.request_of_request request with
    | Error error -> Eta.Effect.fail error
    | Ok request ->
        H1_client.request ~max_response_body_bytes ?host_eio ?ca_file ~sw ~net
          request
        |> Eta.Effect.map H1.response
  in
  let stats_impl () =
    Eta.Effect.pure
      {
        protocol = H1;
        active = 0;
        idle = 0;
        capacity = 0;
        opened = 0;
        released = 0;
      }
  in
  let shutdown_impl () = Eta.Effect.unit in
  { protocol = H1; request_impl; stats_impl; shutdown_impl }

let run_host_h1 host_eio ~sw ~clock ~net ?tracer ?sampler ?auto_instrument
    ?logger ?meter ?random ?island_pool ?blocking_pool ?capture_backtrace
    ?max_response_body_bytes ?ca_file f =
  Eta.Runtime.with_host_eio host_eio ~sw ~clock ?tracer ?sampler
    ?auto_instrument ?logger ?meter ?random ?island_pool ?blocking_pool
    ?capture_backtrace @@ fun runtime ->
  let client =
    make_h1_direct ~sw ~net ~host_eio ?max_response_body_bytes ?ca_file ()
  in
  Eta.Runtime.run runtime (f client)

let make ~sw ~net
    ?(max_response_body_bytes = default_max_response_body_bytes) ?ca_file () =
  if max_response_body_bytes < 0 then
    invalid_arg "Eta_http.Client.make: max_response_body_bytes must be >= 0";
  let opened = ref 0 in
  let released = ref 0 in
  let last_protocol = ref Auto in
  let h2_connections = Hashtbl.create 8 in
  let h2_key target =
    Printf.sprintf "https://%s:%d" target.Connect.host target.port
  in
  let h2_connections_values () =
    Hashtbl.fold (fun _ connection acc -> connection :: acc) h2_connections []
  in
  let h2_connection_for target =
    let key = h2_key target in
    match Hashtbl.find_opt h2_connections key with
    | Some connection when not (Connection.is_closed connection) ->
        Some connection
    | Some _ ->
        Hashtbl.remove h2_connections key;
        None
    | None -> None
  in
  let note_open () = Eta.Effect.sync (fun () -> incr opened) in
  let close_counted flow =
    Eta.Effect.sync (fun () ->
        incr released;
        try Eio.Flow.close flow with _ -> ())
  in
  let h1_on_flow flow request =
    match H1.request_of_request request with
    | Error error -> close_counted flow |> Eta.Effect.bind (fun () -> Eta.Effect.fail error)
    | Ok h1_request ->
        H1_client.request_on_flow ~release:(fun () -> close_counted flow)
          ~max_response_body_bytes ~flow h1_request
        |> Eta.Effect.map H1.response
  in
  let h2_on_connection connection request url =
    last_protocol := H2;
    H2.request_on_connection connection request url
  in
  let h2_config =
    { H2_proto.Config.default with
      read_buffer_size = 131072;
      response_body_buffer_size = 131072;
      request_body_buffer_size = 131072;
    }
  in
  let h2_on_tls target tls request url =
    let key = h2_key target in
    let connection =
      Connection.create ~sw ~flow:(tls :> Connect.tcp_flow)
        ~config:h2_config ~reader_buffer_size:(512 * 1024)
        ~on_close:(fun () ->
          incr released;
          Hashtbl.remove h2_connections key)
        ()
    in
    Hashtbl.replace h2_connections key connection;
    h2_on_connection connection request url
  in
  let dispatch_tls target (tls, alpn) request url =
    dispatch_alpn
      ~close:(fun () -> close_counted (tls :> Connect.tcp_flow))
      ~use_h1:(fun () ->
        last_protocol := H1;
        h1_on_flow (tls :> Connect.tcp_flow) request)
      ~use_h2:(fun () -> h2_on_tls target tls request url)
      request alpn
  in
  let request_impl request =
    match request_url request with
    | Error error -> Eta.Effect.fail error
    | Ok url ->
        let target = Connect.target_of_url url in
        (match (target.Connect.scheme, h2_connection_for target) with
        | Https, Some connection -> h2_on_connection connection request url
        | _ ->
            Connect.connect_tcp ~sw ~net ~method_:request.method_ target
            |> Eta.Effect.bind (fun tcp ->
                   note_open ()
                   |> Eta.Effect.bind (fun () ->
                          match target.Connect.scheme with
                          | Http ->
                              last_protocol := H1;
                              h1_on_flow tcp request
                          | Https ->
                              Connect.connect_tls ?ca_file
                                ~method_:request.method_ target tcp
                              |> Eta.Effect.bind (fun (tls, alpn) ->
                                     dispatch_tls target (tls, alpn) request url))))
  in
  let stats_impl () =
    Eta.Effect.sync (fun () ->
        let h2_stats =
          h2_connections_values ()
          |> List.fold_left
               (fun acc connection ->
                 let stats = Connection.stats connection in
                 {
                   acc with
                   active = acc.active + stats.active;
                   capacity = acc.capacity + stats.max_concurrent;
                   idle = acc.idle + 1;
                 })
               {
                 protocol = H2;
                 active = 0;
                 idle = 0;
                 capacity = 0;
                 opened = 0;
                 released = 0;
               }
        in
        {
          protocol = !last_protocol;
          active = h2_stats.active;
          idle = h2_stats.idle;
          capacity = h2_stats.capacity;
          opened = !opened;
          released = !released;
        })
  in
  let shutdown_impl () =
    Eta.Effect.sync (fun () ->
        h2_connections_values () |> List.iter Connection.shutdown;
        Hashtbl.clear h2_connections)
  in
  { protocol = Auto; request_impl; stats_impl; shutdown_impl }

let make_for_test ~protocol ~request ~stats ~shutdown =
  {
    protocol;
    request_impl = request;
    stats_impl = stats;
    shutdown_impl = shutdown;
  }

module For_test = struct
  let dispatch_alpn = dispatch_alpn
  let h2_informational_status = H2.informational_status
  let request_h2_on_connection = H2.request_on_connection
end
