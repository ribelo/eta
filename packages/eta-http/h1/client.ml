(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta

module Body = Eta_http_body.Stream
module Connect = Eta_http_transport.Connect
module Error = Eta_http_error.Error
module Header = Eta_http_core.Header
module Url = Eta_http_core.Url

type flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

type request_body = Empty | Fixed of bytes list

type request = {
  method_ : string;
  url : Url.t;
  headers : Header.t;
  body : request_body;
}

type response = {
  status : int;
  headers : Header.t;
  body : Body.t;
}

type conn = {
  flow : flow;
  mutable used : bool;
  mutable reusable : bool;
}

type pool_error =
  [ `Http of Error.t
  | `Pool_shutdown
  | `Pool_shutdown_timeout
  | `Health_probe_timeout
  ]

type pool = {
  origin : string;
  target : Connect.target;
  pool : (conn, pool_error) Eta.Pool.t;
}

let uri request = Url.to_string request.url

let make_error request kind =
  Error.make ~protocol:H1 ~method_:request.method_ ~uri:(uri request) kind

let protocol_violation request kind message =
  make_error request (Connection_protocol_violation { kind; message })

let io_closed request during =
  make_error request (Connection_closed { during })

let pool_context_error ~method_ ~uri = function
  | `Http error -> error
  | `Pool_shutdown | `Pool_shutdown_timeout ->
      Error.make ~protocol:H1 ~method_ ~uri Pool_shutdown
  | `Health_probe_timeout ->
      Error.make ~protocol:H1 ~method_ ~uri
        (Connection_protocol_violation
           { kind = "pool_health"; message = "health probe timed out" })

let map_http_error effect = Effect.catch (fun e -> Effect.fail (`Http e)) effect

let close_flow request flow =
  Effect.sync (fun () ->
      try Ok (Eio.Flow.close flow) with _ -> Error ())
  |> Effect.bind (function
       | Ok () -> Effect.unit
       | Error () -> Effect.fail (io_closed request Http_response))

let close_conn conn =
  Effect.sync (fun () ->
      try Eio.Flow.close conn.flow with _ -> ())

let write_body = function
  | Empty -> Write.Empty
  | Fixed chunks -> Write.Fixed chunks

let write_request flow request =
  try
    match
      Write.write_to_flow flow ~method_:request.method_ ~url:request.url
        ~headers:request.headers ~body:(write_body request.body)
    with
    | Error error -> Error error
    | Ok () -> Ok ()
  with _ -> Error (io_closed request Http_request)

let rejects_chunked request headers =
  match Header.get "transfer-encoding" headers with
  | Some value when String.equal (String.lowercase_ascii (String.trim value)) "chunked" ->
      Error
        (make_error request
           (Decode_error
              {
                codec = "chunked";
                message = "chunked response bodies land in S3";
              }))
  | _ -> Ok ()

let response_has_body request status =
  (not (String.equal (String.uppercase_ascii request.method_) "HEAD"))
  && (status < 100 || status >= 200)
  && status <> 204 && status <> 304

let connection_close_requested headers =
  match Header.get "connection" headers with
  | None -> false
  | Some value ->
      String.equal "close" (String.lowercase_ascii (String.trim value))

let max_header_bytes = 32 * 1024
let max_response_body_bytes = 1_048_576
let max_response_headers = 256

let parse_error request error =
  protocol_violation request "parse" (Parse.parse_error_to_string error)

let read_more flow read_buffer buffer used =
  if used >= Bytes.length buffer then
    Error (Parse.Header_section_too_large { limit = max_header_bytes })
  else
    let len = Bytes.length buffer - used in
    try
      let read =
        Eio.Flow.single_read flow (Cstruct.sub read_buffer used len)
      in
      if read = 0 then Error Parse.Partial
      else (
        Cstruct.blit_to_bytes read_buffer used buffer used read;
        Ok (used + read))
    with End_of_file -> Error Parse.Partial

let read_body_bytes flow request body offset remaining =
  if remaining = 0 then Ok body
  else
    let read_buffer = Cstruct.create remaining in
    let rec loop offset remaining =
      if remaining = 0 then Ok body
      else
        try
          let read =
            Eio.Flow.single_read flow (Cstruct.sub read_buffer 0 remaining)
          in
          if read = 0 then Error (io_closed request Http_response)
          else (
            Cstruct.blit_to_bytes read_buffer 0 body offset read;
            loop (offset + read) (remaining - read))
        with End_of_file -> Error (io_closed request Http_response)
    in
    loop offset remaining

let finish_response flow request buffer used raw_headers raw =
  let status = Parse.raw_status raw in
  let headers =
    Header.of_list (Parse.raw_headers_to_list buffer raw_headers raw)
  in
  if not (response_has_body request status) then
    Ok (status, headers, Bytes.empty)
  else
    match rejects_chunked request headers with
    | Error error -> Error error
    | Ok () -> (
        let expected =
          match Parse.raw_content_length raw with None -> 0 | Some length -> length
        in
        if expected > max_response_body_bytes then
          Error
            (parse_error request
               (Parse.Body_too_large
                  { limit = max_response_body_bytes; length = expected }))
        else if expected = 0 then Ok (status, headers, Bytes.empty)
        else
          let body = Bytes.create expected in
          let body_off = Parse.raw_body_off raw in
          let available = min expected (max 0 (used - body_off)) in
          if available > 0 then Bytes.blit buffer body_off body 0 available;
          match
            read_body_bytes flow request body available (expected - available)
          with
          | Error _ as error -> error
          | Ok body -> Ok (status, headers, body))

let read_response_bytes flow request =
  let buffer = Bytes.create max_header_bytes in
  let read_buffer = Cstruct.create max_header_bytes in
  let raw_headers = Parse.create_raw_headers max_response_headers in
  let raw = Parse.create_raw_response () in
  let rec loop used =
    match
      Parse.parse_raw buffer ~len:used ~max_header_bytes ~headers:raw_headers
        raw
    with
    | code when code = Parse.raw_ok || code = Parse.raw_body_truncated ->
        finish_response flow request buffer used raw_headers raw
    | code when code = Parse.raw_partial -> (
        match read_more flow read_buffer buffer used with
        | Ok used -> loop used
        | Error Parse.Partial -> Error (io_closed request Http_response)
        | Error error -> Error (parse_error request error))
    | code ->
        Error (parse_error request (Parse.raw_error buffer raw ~max_header_bytes code))
  in
  loop 0

let request_on_flow ?release ~flow request =
  let release = Option.value release ~default:(fun () -> close_flow request flow) in
  Effect.sync (fun () ->
      match write_request flow request with
      | Error error -> Error error
      | Ok () -> read_response_bytes flow request)
  |> Effect.bind (function
       | Error error ->
           Effect.catch (fun _ -> Effect.unit) (close_flow request flow)
           |> Effect.bind (fun () -> Effect.fail error)
       | Ok (status, headers, body_bytes) ->
           let body =
             Body.of_bytes ~release [ body_bytes ]
           in
           Effect.pure { status; headers; body })

type release_ack = unit Channel.t

let send_best_effort ch value =
  Channel.try_send ch value
  |> Effect.map (function `Sent | `Full | `Closed -> ())

let release_body release_ch =
  let ack = Channel.create ~capacity:1 () in
  Channel.try_send release_ch ack
  |> Effect.bind (function
       | `Sent ->
           Channel.recv ack
           |> Effect.catch (function `Closed -> Effect.unit)
       | `Full | `Closed -> Effect.unit)

let origin_key url =
  Printf.sprintf "%s://%s:%d"
    (Url.scheme_to_string (Url.scheme url))
    (Url.host url) (Url.effective_port url)

let origin_error pool request =
  make_error request
    (Connection_protocol_violation
       {
         kind = "pool_origin";
         message =
           Printf.sprintf "request origin %s does not match pool origin %s"
             (origin_key request.url) pool.origin;
       })

let health_error (target : Connect.target) message =
  Error.make ~protocol:H1 ~method_:"*" ~uri:(Url.to_string target.Connect.url)
    (Connection_protocol_violation { kind = "pool_health"; message })

let default_health_check (target : Connect.target) flow =
  let probe =
    Effect.sync (fun () ->
        let reader = Eio.Buf_read.of_flow ~initial_size:1 ~max_size:1 flow in
        match Eio.Buf_read.peek_char reader with
        | None -> `Closed
        | Some _ -> `Unexpected_data)
    |> Effect.bind (function
         | `Closed ->
             Effect.fail (`Http (health_error target "idle connection closed"))
         | `Unexpected_data ->
             Effect.fail
               (`Http (health_error target "idle connection had unread bytes")))
  in
  Effect.timeout_as (Eta.Duration.ms 1) ~on_timeout:`Health_probe_timeout probe
  |> Effect.catch (function
       | `Health_probe_timeout -> Effect.unit
       | `Http error -> Effect.fail (`Http error))

let open_conn ~sw ~net ~authenticator (target : Connect.target) =
  let wrap flow = { flow; used = false; reusable = true } in
  Connect.connect_tcp ~sw ~net ~method_:"*" target
  |> Effect.bind (fun tcp ->
         match target.Connect.scheme with
         | Http -> Effect.pure (wrap (tcp :> flow))
         | Https ->
             Connect.connect_tls ~alpn_protocols:[ "http/1.1" ] ~authenticator
               ~method_:"*" target tcp
             |> Effect.map (fun tls -> wrap (tls :> flow)))
  |> map_http_error

let make_pool ?(max_size = 8) ?max_idle ?health_check ~sw ~net ~authenticator
    url =
  let target = Connect.target_of_url url in
  let origin = origin_key url in
  let health_check =
    match health_check with
    | Some health_check ->
        fun conn ->
          if not conn.reusable then
            Effect.fail (`Http (health_error target "connection marked unreusable"))
          else if not conn.used then Effect.unit
          else health_check conn.flow |> map_http_error
    | None ->
        fun conn ->
          if not conn.reusable then
            Effect.fail (`Http (health_error target "connection marked unreusable"))
          else if not conn.used then Effect.unit
          else default_health_check target conn.flow
  in
  Eta.Pool.create ~name:"eta-http.h1.pool" ~kind:"http.client" ~max_size
    ?max_idle ~acquire:(open_conn ~sw ~net ~authenticator target)
    ~release:close_conn ~health_check ()
  |> Effect.catch (fun err ->
         Effect.fail
           (pool_context_error ~method_:"*" ~uri:(Url.to_string url) err))
  |> Effect.map (fun pool -> { origin; target; pool })

let request_owner pool request response_ch release_ch =
  let ack = ref None in
  let report_error error = send_best_effort response_ch (Error error) in
  let hold_resource =
    Eta.Pool.with_resource pool.pool (fun conn ->
        request_on_flow ~release:(fun () -> release_body release_ch)
          ~flow:conn.flow request
        |> Effect.catch (fun error ->
               conn.reusable <- false;
               Effect.fail (`Http error))
        |> Effect.bind (fun response ->
               conn.used <- true;
               if connection_close_requested response.headers then
                 conn.reusable <- false;
               Channel.try_send response_ch (Ok response)
               |> Effect.bind (function
                    | `Sent ->
                        Channel.recv release_ch
                        |> Effect.map (fun release_ack -> ack := Some release_ack)
                        |> Effect.catch (function `Closed -> Effect.unit)
                    | `Full | `Closed -> Effect.unit)))
  in
  hold_resource
  |> Effect.bind (fun () ->
         match !ack with
         | None -> Effect.unit
         | Some release_ack -> send_best_effort release_ack ())
  |> Effect.catch (fun err ->
         report_error
           (pool_context_error ~method_:request.method_ ~uri:(uri request) err))

let request_with_pool pool request =
  if not (String.equal (origin_key request.url) pool.origin) then
    Effect.fail (origin_error pool request)
  else
    let response_ch = Channel.create ~capacity:1 () in
    let release_ch = Channel.create ~capacity:1 () in
    let returned = ref false in
    let close_if_pending () =
      Effect.sync (fun () ->
          if not !returned then (
            Channel.close response_ch;
            Channel.close release_ch))
    in
    Effect.scoped
      (Effect.acquire_release ~acquire:Effect.unit ~release:close_if_pending
      |> Effect.bind (fun () ->
             Effect.Private.daemon
               (request_owner pool request response_ch release_ch)
             |> Effect.bind (fun () ->
                    Channel.recv response_ch
                    |> Effect.catch (function
                         | `Closed ->
                             Effect.pure
                               (Error (io_closed request Http_response)))
                    |> Effect.bind (function
                         | Error error -> Effect.fail error
                         | Ok response ->
                             returned := true;
                             Effect.pure response))))

let pool_stats pool = Eta.Pool.stats pool.pool
let pool_origin pool = pool.origin

let shutdown_pool pool =
  Eta.Pool.shutdown pool.pool
  |> Effect.catch (fun err ->
         Effect.fail
           (pool_context_error ~method_:"*" ~uri:(Url.to_string pool.target.url)
              err))

let request ~sw ~net ~authenticator request =
  let target = Connect.target_of_url request.url in
  Connect.connect_tcp ~sw ~net ~method_:request.method_ target
  |> Effect.bind (fun tcp ->
         match target.scheme with
         | Http -> request_on_flow ~flow:tcp request
         | Https ->
             Connect.connect_tls ~alpn_protocols:[ "http/1.1" ] ~authenticator
               ~method_:request.method_ target tcp
             |> Effect.bind (fun tls -> request_on_flow ~flow:tls request))
