(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Body = Eta_http_body.Stream
module Connect = Eta_http_transport.Connect
module Dispatch = Eta_http_transport.Dispatch
module Error = Eta_http_error.Error
module Header = Eta_http_core.Header
module Url = Eta_http_core.Url

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
  request_impl : Request.t -> (Response.t, Eta_http_error.Error.t) Eta.Effect.t;
  stats_impl : unit -> (stats, Eta_http_error.Error.t) Eta.Effect.t;
  shutdown_impl : unit -> (unit, Eta_http_error.Error.t) Eta.Effect.t;
}

let protocol_to_string = function H1 -> "h1" | H2 -> "h2" | Auto -> "auto"
let default_max_response_body_bytes =
  Eta_http_h1.Client.default_max_response_body_bytes

let protocol t = t.protocol
let stats t = t.stats_impl ()
let shutdown t = t.shutdown_impl ()
let request t req = t.request_impl req
let request_with_retry ?policy t req = Retry.run ?policy t.request_impl req

let default_authenticator =
  let authenticator = lazy (Ca_certs.authenticator ()) in
  fun ?ip ~host certificates ->
    match Lazy.force authenticator with
    | Ok authenticate -> authenticate ?ip ~host certificates
    | Error (`Msg msg) -> Error (`Msg msg)

let resolve_authenticator = function
  | Some authenticator -> authenticator
  | None -> default_authenticator

let h1_body = function
  | Request.Empty -> Eta_http_h1.Client.Empty
  | Fixed chunks -> Eta_http_h1.Client.Fixed chunks
  | Stream body -> Eta_http_h1.Client.Stream body
  | Rewindable_stream { length; make } ->
      Eta_http_h1.Client.Rewindable_stream { length; make }

let h1_request_of_request request =
  match
    try Ok (Request.url request) with Invalid_argument message -> Error message
  with
  | Ok url ->
      Ok
        {
          Eta_http_h1.Client.method_ = request.Request.method_;
          url;
          headers = request.headers;
          body = h1_body request.body;
        }
  | Error message ->
      Error
        (Eta_http_error.Error.make ~method_:request.method_ ~uri:request.uri
           (Connection_protocol_violation { kind = "url"; message }))

let response_of_h1 (response : Eta_http_h1.Client.response) =
  Response.make ~status:response.Eta_http_h1.Client.status
    ~headers:response.headers ~trailers:response.trailers ~body:response.body ()

let request_url request =
  match
    try Ok (Request.url request) with Invalid_argument message -> Error message
  with
  | Ok url -> Ok url
  | Error message ->
      Error
        (Error.make ~method_:request.Request.method_ ~uri:request.uri
           (Connection_protocol_violation { kind = "url"; message }))

let h2_error request kind =
  Error.make ~protocol:Error.H2 ~method_:request.Request.method_ ~uri:request.uri
    kind

let h2_protocol_violation request kind message =
  h2_error request (Connection_protocol_violation { kind; message })

let h2_closed request during = h2_error request (Connection_closed { during })

let h2_pp_client_error = function
  | `Malformed_response message -> "malformed_response:" ^ message
  | `Invalid_response_body_length _ -> "invalid_response_body_length"
  | `Protocol_error (code, message) ->
      Format.asprintf "protocol_error:%a:%s" H2.Error_code.pp_hum code message
  | `Exn exn -> "exn:" ^ Printexc.to_string exn

let h2_skip_header name =
  match Header.normalize_name name with
  | "connection" | "host" | "keep-alive" | "proxy-connection"
  | "transfer-encoding" | "upgrade" ->
      true
  | normalized -> String.length normalized > 0 && Char.equal normalized.[0] ':'

let h2_headers request url =
  match Header.validate request.Request.headers with
  | Some kind -> Error (h2_error request kind)
  | None ->
      let user_headers =
        request.Request.headers
        |> List.filter_map (fun (name, value) ->
               if h2_skip_header name then None
               else Some (Header.normalize_name name, value))
      in
      Ok (H2.Headers.of_list ((":authority", Url.authority url) :: user_headers))

let h2_method = function
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

let h2_request_of_request request url =
  match h2_headers request url with
  | Error _ as error -> error
  | Ok headers ->
      Ok
        (H2.Request.create
           ~scheme:(Url.scheme_to_string (Url.scheme url))
           ~headers
           (h2_method (Request.method_value request))
           (Url.origin_form url))

let h2_read_once request flow reader =
  Eta.Effect.sync (fun () ->
      try Ok (Eta_http_h2.Multiplexer.read_client_once ~flow reader)
      with
      | End_of_file -> Ok (Eta_http_h2.Multiplexer.Eof 0)
      | exn -> Error (Printexc.to_string exn))
  |> Eta.Effect.bind (function
       | Ok result -> Eta.Effect.pure result
       | Error message ->
           Eta.Effect.fail (h2_protocol_violation request "read" message))

let h2_flush_client request flow client =
  Eta.Effect.sync (fun () ->
      try Ok (Eta_http_h2.Writer.drain_client ~flow client)
      with exn -> Error (Printexc.to_string exn))
  |> Eta.Effect.bind (function
       | Ok (Eta_http_h2.Writer.Yield _) -> Eta.Effect.unit
       | Ok (Close { code; _ }) ->
           Eta.Effect.fail
             (h2_protocol_violation request "write"
                (Printf.sprintf "client writer closed with code %d" code))
       | Error message ->
           Eta.Effect.fail (h2_protocol_violation request "write" message))

let h2_write_chunk writer chunk =
  Eta.Effect.sync (fun () ->
      H2.Body.Writer.write_string writer (Bytes.unsafe_to_string chunk))

let rec h2_write_stream_flushed ~flush writer body =
  Body.read body
  |> Eta.Effect.bind (function
       | None -> Eta.Effect.unit
       | Some chunk ->
           h2_write_chunk writer chunk
           |> Eta.Effect.bind (fun () -> flush ())
           |> Eta.Effect.bind (fun () -> h2_write_stream_flushed ~flush writer body))

let h2_write_body_flushed ~flush writer = function
  | Request.Empty -> flush ()
  | Fixed chunks ->
      chunks
      |> List.map (fun chunk ->
             h2_write_chunk writer chunk |> Eta.Effect.bind (fun () -> flush ()))
      |> Eta.Effect.concat
  | Stream body -> h2_write_stream_flushed ~flush writer body
  | Rewindable_stream { make; _ } ->
      h2_write_stream_flushed ~flush writer (make ())

let h2_response_headers response =
  H2.Headers.to_list response.H2.Response.headers
  |> List.filter (fun (name, _) ->
         String.length name = 0 || not (Char.equal name.[0] ':'))

let h2_response_has_body request status =
  (not (String.equal (String.uppercase_ascii request.Request.method_) "HEAD"))
  && (status < 100 || status >= 200)
  && status <> 204 && status <> 304

let deliver_result_once result_ref value =
  match !result_ref with
  | Some _ -> false
  | None ->
      result_ref := Some value;
      true

let h2_trailer_result request =
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
    match Eta_http_h2.Security.validate_headers headers with
    | Some kind -> resolve (Error (h2_error request kind))
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

let h2_body_pump request flow client reader =
  h2_flush_client request flow client
  |> Eta.Effect.bind (fun () ->
         h2_read_once request flow reader
         |> Eta.Effect.bind (function
              | Eta_http_h2.Multiplexer.Security_error kind ->
                  Eta.Effect.fail (h2_error request kind)
              | result -> Eta.Effect.pure result))

let request_h2_on_flow ?(on_release = fun () -> Eta.Effect.unit) ~flow request
    url =
  let result_ref = ref None in
  let body_error = ref None in
  let response_started = ref false in
  let cleanup_before_return = ref false in
  let trailers, resolve_trailers, resolve_empty_trailers, resolve_trailer_error =
    h2_trailer_result request
  in
  let set_body_error error =
    body_error := Some error;
    resolve_trailer_error error
  in
  let mux =
    Eta_http_h2.Multiplexer.create ~error_handler:(fun error ->
        let error =
          h2_protocol_violation request "connection" (h2_pp_client_error error)
        in
        if !response_started then set_body_error error
        else ignore (deliver_result_once result_ref (Error error)))
      ()
  in
  let client = Eta_http_h2.Multiplexer.client_connection mux in
  let reader = Eta_http_h2.Multiplexer.create_client_reader client in
  let cleanup () =
    Eta.Effect.sync (fun () ->
        Eta_http_h2.Multiplexer.shutdown mux;
        try Eio.Flow.close flow with _ -> ())
    |> Eta.Effect.bind (fun () -> on_release ())
  in
  let cleanup_then_fail error =
    cleanup () |> Eta.Effect.bind (fun () -> Eta.Effect.fail error)
  in
  let close_no_body stream body =
    resolve_empty_trailers ();
    H2.Body.Reader.close body;
    Eta_http_h2.Multiplexer.mark_complete mux stream;
    ignore (Eta_http_h2.Multiplexer.release mux stream);
    cleanup_before_return := true
  in
  let response_body stream body =
    Eta_http_h2.Multiplexer.body_stream
      ~closed_error:(h2_closed request Http_response)
      ~poll_error:(fun () -> !body_error)
      ~on_eof:resolve_empty_trailers
      ~on_release:(fun _ ->
        resolve_trailer_error (h2_closed request Http_response);
        cleanup ())
      ~pump:(fun () -> h2_body_pump request flow client reader)
      mux stream body
  in
  let open_request h2_request =
    Eta_http_h2.Multiplexer.request mux ~tag:0 h2_request
      ~trailers_handler:(fun headers -> resolve_trailers (H2.Headers.to_list headers))
      ~error_handler:(fun stream error ->
        Eta_http_h2.Multiplexer.mark_remote_reset mux
          (Eta_http_h2.Stream_state.id stream);
        let error =
          h2_protocol_violation request "stream" (h2_pp_client_error error)
        in
        if !response_started then set_body_error error
        else
          ignore (deliver_result_once result_ref (Error error)))
      ~response_handler:(fun stream response body ->
        response_started := true;
        let status = H2.Status.to_code response.H2.Response.status in
        let headers = h2_response_headers response in
        match Eta_http_h2.Security.validate_headers headers with
        | Some kind ->
            H2.Body.Reader.close body;
            ignore (Eta_http_h2.Multiplexer.release mux stream);
            cleanup_before_return := true;
            ignore (deliver_result_once result_ref (Error (h2_error request kind)))
        | None when h2_response_has_body request status ->
          let body = response_body stream body in
          let response = Response.make ~status ~headers ~trailers ~body () in
          ignore (deliver_result_once result_ref (Ok response))
        | None ->
          let response =
            Response.make ~status ~headers ~trailers ~body:(Body.empty ()) ()
          in
          ignore (deliver_result_once result_ref (Ok response));
          close_no_body stream body)
  in
  match h2_request_of_request request url with
  | Error error -> cleanup_then_fail error
  | Ok h2_request -> (
  match open_request h2_request with
  | Error Admission_rejected ->
      cleanup_then_fail
        (h2_error request (Stream_admission_rejected { limit = 128 }))
  | Error Connection_closed -> cleanup_then_fail (h2_closed request Http_request)
  | Error (Request_failed message) ->
      cleanup_then_fail (h2_protocol_violation request "request" message)
  | Ok opened ->
      let flush () = h2_flush_client request flow client in
      h2_write_body_flushed ~flush opened.request_body request.body
      |> Eta.Effect.bind (fun () ->
             Eta.Effect.sync (fun () -> H2.Body.Writer.close opened.request_body))
      |> Eta.Effect.bind flush
      |> Eta.Effect.bind (fun () ->
             let rec wait_for_response () =
               match !result_ref with
               | Some (Ok response) ->
                   if !cleanup_before_return then
                     cleanup () |> Eta.Effect.map (fun () -> response)
                   else Eta.Effect.pure response
               | Some (Error error) -> cleanup_then_fail error
               | None -> (
                   h2_read_once request flow reader
                   |> Eta.Effect.bind (function
                        | Eta_http_h2.Multiplexer.Read _ -> wait_for_response ()
                        | Security_error kind ->
                            cleanup_then_fail (h2_error request kind)
                        | Eof _ | Close -> (
                            match !result_ref with
                            | Some (Ok response) ->
                                if !cleanup_before_return then
                                  cleanup () |> Eta.Effect.map (fun () -> response)
                                else Eta.Effect.pure response
                            | Some (Error error) -> cleanup_then_fail error
                            | None ->
                                cleanup_then_fail (h2_closed request Http_response))))
             in
             wait_for_response ()))
let make_h1 ~sw ~net ?authenticator
    ?(max_response_body_bytes = default_max_response_body_bytes) () =
  if max_response_body_bytes < 0 then
    invalid_arg "Eta_http.Client.make_h1: max_response_body_bytes must be >= 0";
  let authenticator = resolve_authenticator authenticator in
  let pools = Hashtbl.create 8 in
  let pool_values () = Hashtbl.fold (fun _ pool acc -> pool :: acc) pools [] in
  let pool_for request =
    let key = Eta_http_h1.Client.origin_key request.Eta_http_h1.Client.url in
    match Hashtbl.find_opt pools key with
    | Some pool -> Eta.Effect.pure pool
    | None ->
        Eta_http_h1.Client.make_pool ~max_response_body_bytes ~sw ~net
          ~authenticator request.url
        |> Eta.Effect.map (fun pool ->
               Hashtbl.replace pools key pool;
               pool)
  in
  let request_impl request =
    match h1_request_of_request request with
    | Error error -> Eta.Effect.fail error
    | Ok request ->
        pool_for request
        |> Eta.Effect.bind (fun pool ->
               Eta_http_h1.Client.request_with_pool pool request)
        |> Eta.Effect.map response_of_h1
  in
  let stats_impl () =
    Eta.Effect.sync (fun () ->
        pool_values ()
        |> List.fold_left
             (fun acc pool ->
               let stats = Eta_http_h1.Client.pool_stats pool in
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
    pool_values () |> List.map Eta_http_h1.Client.shutdown_pool |> Eta.Effect.concat
  in
  { protocol = H1; request_impl; stats_impl; shutdown_impl }


let make ~sw ~net ?authenticator
    ?(max_response_body_bytes = default_max_response_body_bytes) () =
  if max_response_body_bytes < 0 then
    invalid_arg "Eta_http.Client.make: max_response_body_bytes must be >= 0";
  let authenticator = resolve_authenticator authenticator in
  let opened = ref 0 in
  let released = ref 0 in
  let last_protocol = ref Auto in
  let note_open () = Eta.Effect.sync (fun () -> incr opened) in
  let close_counted flow =
    Eta.Effect.sync (fun () ->
        incr released;
        try Eio.Flow.close flow with _ -> ())
  in
  let h1_on_flow flow request =
    match h1_request_of_request request with
    | Error error -> close_counted flow |> Eta.Effect.bind (fun () -> Eta.Effect.fail error)
    | Ok h1_request ->
        Eta_http_h1.Client.request_on_flow ~release:(fun () -> close_counted flow)
          ~max_response_body_bytes ~flow h1_request
        |> Eta.Effect.map response_of_h1
  in
  let unsupported_alpn request protocol =
    Error.make ~protocol:Error.Unknown ~method_:request.Request.method_
      ~uri:request.uri
      (Tls_handshake_error
         {
           stage = Alpn_negotiation;
           message = "unsupported ALPN protocol " ^ protocol;
         })
  in
  let dispatch_tls target tls request url =
    Connect.negotiated_alpn ~method_:request.Request.method_ target tls
    |> Eta.Effect.bind (fun alpn ->
           match Dispatch.decide_alpn alpn with
           | Error protocol -> Eta.Effect.fail (unsupported_alpn request protocol)
           | Ok Dispatch.Use_h1 ->
               last_protocol := H1;
               h1_on_flow (tls :> Connect.tcp_flow) request
           | Ok Dispatch.Use_h2 ->
               last_protocol := H2;
               request_h2_on_flow
                 ~on_release:(fun () -> Eta.Effect.sync (fun () -> incr released))
                 ~flow:(tls :> Connect.tcp_flow) request url)
  in
  let request_impl request =
    match request_url request with
    | Error error -> Eta.Effect.fail error
    | Ok url ->
        let target = Connect.target_of_url url in
        Connect.connect_tcp ~sw ~net ~method_:request.method_ target
        |> Eta.Effect.bind (fun tcp ->
               note_open ()
               |> Eta.Effect.bind (fun () ->
                      match target.Connect.scheme with
                      | Http ->
                          last_protocol := H1;
                          h1_on_flow tcp request
                      | Https ->
                          Connect.connect_tls ~authenticator
                            ~method_:request.method_ target tcp
                          |> Eta.Effect.bind (fun tls ->
                                 dispatch_tls target tls request url)))
  in
  let stats_impl () =
    Eta.Effect.sync (fun () ->
        {
          protocol = !last_protocol;
          active = 0;
          idle = 0;
          capacity = 0;
          opened = !opened;
          released = !released;
        })
  in
  let shutdown_impl () = Eta.Effect.unit in
  { protocol = Auto; request_impl; stats_impl; shutdown_impl }

let make_for_test ~protocol ~request ~stats ~shutdown =
  {
    protocol;
    request_impl = request;
    stats_impl = stats;
    shutdown_impl = shutdown;
  }
