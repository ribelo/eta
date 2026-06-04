(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta
open H1_client_types

module Connect = Connect
module Error = Error
module Header = Header
module Url = Url

type nonrec request_body = request_body =
  | Empty
  | Fixed of bytes list
  | Stream of Stream.t
  | Rewindable_stream of {
      length : int option;
      make : (unit -> Stream.t) @@ many;
    }

type nonrec request = request = {
  method_ : string;
  url : Url.t;
  headers : Header.t;
  body : request_body;
}

type nonrec response = response = {
  status : int;
  headers : Header.t;
  body : Stream.t;
  trailers : (unit -> (Header.t, Error.t) Effect.t) @@ many;
}

type nonrec pool = pool

let default_max_response_body_bytes =
  H1_client_response_reader.default_max_response_body_bytes

let request_on_flow ?host_eio ?(on_unread_body @ many = fun () -> Effect.unit)
    ?(max_response_body_bytes = default_max_response_body_bytes)
    ?(release @ many) ~flow request =
  if max_response_body_bytes < 0 then
    invalid_arg
      "Eta_http.H1.Client.request_on_flow: max_response_body_bytes must be >= 0";
  let release =
    Option.value release
      ~default:(fun () -> H1_client_errors.close_flow request flow)
  in
  let release_on_error error =
    Effect.catch (fun _ -> Effect.unit) (release ())
    |> Effect.bind (fun () -> Effect.fail error)
  in
  H1_client_request_writer.write_request ?host_eio flow request
  |> Effect.catch release_on_error
  |> Effect.bind (fun () ->
         let rec read_final_response initial =
           Effect.sync (fun () ->
               H1_client_response_reader.read_response_head ?host_eio ~initial
                 flow request)
           |> Effect.catch release_on_error
           |> Effect.bind (function
                | Error error -> release_on_error error
                | Ok (head : H1_client_response_reader.response_head)
                  when head.status >= 100 && head.status < 200
                       && head.status <> 101 ->
                    read_final_response head.initial
                | Ok head ->
                    let body, trailers =
                      H1_client_response_reader.response_body ?host_eio
                        ~max_response_body_bytes ~release ~on_unread_body flow
                        request head
                    in
                    Effect.pure
                      {
                        status = head.status;
                        headers = head.headers;
                        body;
                        trailers;
                      })
         in
         read_final_response Bytes.empty)

type release_ack = (unit, unit) Channel.t
type cancel_signal = Cancel

let send_best_effort ch value =
  Channel.try_send ch value
  |> Effect.map (function `Sent | `Full | `Closed | `Closed_with_error _ -> ())

let close_channel ch = Effect.sync (fun () -> Channel.close ch)

let release_body release_ch =
  let ack = Channel.create ~capacity:1 () in
  Channel.try_send release_ch ack
  |> Effect.bind (function
       | `Sent ->
           Channel.recv ack
           |> Effect.catch (function
                | `Closed | `Closed_with_error _ -> Effect.unit)
       | `Full | `Closed | `Closed_with_error _ -> Effect.unit)

(* H1 pools are keyed by HTTP origin, not by full URLs or connection targets:
   scheme, host, and effective port are the only identity fields that may affect
   reuse. The string form is the canonical diagnostic form checked by
   request_with_pool as well as the client pool table. *)
let origin_key url =
  Url.scheme_to_string (Url.scheme url)
  ^ "://"
  ^ Url.host url
  ^ ":"
  ^ string_of_int (Url.effective_port url)

let origin_error pool request =
  H1_client_errors.make_error request
    (Connection_protocol_violation
       {
         kind = "pool_origin";
         message =
           "request origin "
           ^ origin_key request.url
           ^ " does not match pool origin "
           ^ pool.origin;
       })

let health_error (target : Connect.target) message =
  Error.make ~protocol:H1 ~method_:"*" ~uri:(Url.to_string target.Connect.url)
    (Connection_protocol_violation { kind = "pool_health"; message })

let default_health_check (target : Connect.target) conn =
  let now_ms = int_of_float (Unix.gettimeofday () *. 1000.0) in
  if now_ms - conn.last_used_ms < 5000 then Effect.unit
  else
    let probe =
      Effect.sync (fun () ->
          let reader =
            Eio.Buf_read.of_flow ~initial_size:1 ~max_size:1 conn.flow
          in
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

let open_conn ?ca_file ~sw ~net (target : Connect.target) =
  let wrap flow =
    { flow; used = false; reusable = true; last_used_ms = 0 }
  in
  Connect.connect_tcp ~sw ~net ~method_:"*" target
  |> Effect.bind (fun tcp ->
         match target.Connect.scheme with
         | Http -> Effect.pure (wrap (tcp :> flow))
         | Https ->
             Connect.connect_tls ~alpn_protocols:[ "http/1.1" ] ?ca_file
               ~method_:"*" target tcp
             |> Effect.map (fun (tls, _alpn) -> wrap (tls :> flow)))
  |> H1_client_errors.map_http_error

let make_pool ?(max_response_body_bytes = default_max_response_body_bytes)
    ?(max_size = 8) ?max_idle ?health_check ?ca_file ~sw ~net url =
  if max_response_body_bytes < 0 then
    invalid_arg "Eta_http.H1.Client.make_pool: max_response_body_bytes must be >= 0";
  let target = Connect.target_of_url url in
  let origin = origin_key url in
  let health_check =
    match health_check with
    | Some health_check ->
        fun conn ->
          if not conn.reusable then
            Effect.fail (`Http (health_error target "connection marked unreusable"))
          else if not conn.used then Effect.unit
          else health_check conn.flow |> H1_client_errors.map_http_error
    | None ->
        fun conn ->
          if not conn.reusable then
            Effect.fail (`Http (health_error target "connection marked unreusable"))
          else if not conn.used then Effect.unit
          else default_health_check target conn
  in
  Eta.Pool.create ~name:"eta-http.h1.pool" ~kind:"http.client" ~max_size
    ?max_idle ~acquire:(open_conn ?ca_file ~sw ~net target)
    ~release:H1_client_errors.close_conn ~health_check ()
  |> Effect.catch (fun err ->
         Effect.fail
           (H1_client_errors.pool_context_error ~method_:"*"
              ~uri:(Url.to_string url) err))
  |> Effect.map (fun pool -> { origin; target; max_response_body_bytes; pool })

let request_owner pool request response_ch release_ch cancel_ch =
  let ack = ref None in
  let report_error error = send_best_effort response_ch (Error error) in
  let hold_resource =
    Eta.Pool.with_resource pool.pool (fun conn ->
        let request_attempt =
          request_on_flow
            ~on_unread_body:(fun () ->
              conn.reusable <- false;
              Effect.unit)
            ~release:(fun () -> release_body release_ch)
            ~max_response_body_bytes:pool.max_response_body_bytes
            ~flow:conn.flow request
          |> Effect.map (fun response -> `Response response)
          |> Effect.catch (fun error -> Effect.pure (`Request_error error))
        in
        let cancel_wait =
          Channel.recv cancel_ch
          |> Effect.map (fun Cancel -> `Cancelled)
          |> Effect.catch (function
               | `Closed | `Closed_with_error _ -> Effect.pure `Cancelled)
        in
        Effect.race [ request_attempt; cancel_wait ]
        |> Effect.bind (function
             | `Request_error error ->
                 conn.reusable <- false;
                 Effect.fail (`Http error)
             | `Cancelled ->
                 conn.reusable <- false;
                 H1_client_errors.close_flow request conn.flow
                 |> Effect.catch (fun _ -> Effect.unit)
                 |> Effect.bind (fun () ->
                        (* Expected caller cancellation is reported through
                           [response_ch]. The catch below consumes this typed
                           failure before the Effect.daemon boundary, so it
                           must not emit eta.daemon.failure. *)
                        Effect.fail
                          (`Http
                            (H1_client_errors.io_closed request Cancellation)))
             | `Response (response : response) ->
                 conn.used <- true;
                 conn.last_used_ms <- int_of_float (Unix.gettimeofday () *. 1000.0);
                 if H1_client_response_reader.connection_close_requested
                      response.headers
                 then conn.reusable <- false;
                 let abandon_response () =
                   conn.reusable <- false;
                   Effect.unit
                 in
                 Channel.try_send response_ch (Ok response)
                 |> Effect.bind (function
                      | `Sent ->
                          Channel.recv release_ch
                          |> Effect.map (fun release_ack ->
                               ack := Some release_ack)
                          |> Effect.catch (function
                               | `Closed | `Closed_with_error _ ->
                                   abandon_response ())
                      | `Full | `Closed | `Closed_with_error _ ->
                          abandon_response ())))
  in
  hold_resource
  |> Effect.bind (fun () ->
         match !ack with
         | None -> Effect.unit
         | Some release_ack -> send_best_effort release_ack ())
  |> Effect.catch (fun err ->
         report_error
           (H1_client_errors.pool_context_error ~method_:request.method_
              ~uri:(H1_client_errors.uri request) err))

let request_with_pool pool request =
  if not (String.equal (origin_key request.url) pool.origin) then
    Effect.fail (origin_error pool request)
  else
    let response_ch = Channel.create ~capacity:1 () in
    let release_ch = Channel.create ~capacity:1 () in
    let cancel_ch = Channel.create ~capacity:1 () in
    let returned = ref false in
    let close_if_pending () =
      if !returned then Effect.unit
      else
        Channel.try_send cancel_ch Cancel
        |> Effect.bind (fun _ ->
               close_channel response_ch
               |> Effect.bind (fun () -> close_channel release_ch)
               |> Effect.bind (fun () -> close_channel cancel_ch))
    in
    Effect.scoped
      (Effect.acquire_release ~acquire:Effect.unit ~release:close_if_pending
      |> Effect.bind (fun () ->
             Effect.daemon
               (request_owner pool request response_ch release_ch cancel_ch)
             |> Effect.bind (fun () ->
                    Channel.recv response_ch
                    |> Effect.catch (function
                         | `Closed | `Closed_with_error _ ->
                             Effect.pure
                               (Error
                                  (H1_client_errors.io_closed request
                                     Http_response)))
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
           (H1_client_errors.pool_context_error ~method_:"*"
              ~uri:(Url.to_string pool.target.url) err))

let request ?(max_response_body_bytes = default_max_response_body_bytes)
    ?host_eio ?ca_file ~sw ~net request =
  if max_response_body_bytes < 0 then
    invalid_arg "Eta_http.H1.Client.request: max_response_body_bytes must be >= 0";
  let target = Connect.target_of_url request.url in
  Connect.connect_tcp ?host_eio ~sw ~net ~method_:request.method_ target
  |> Effect.bind (fun tcp ->
         match target.scheme with
         | Http ->
             request_on_flow ?host_eio ~max_response_body_bytes ~flow:tcp
               request
         | Https ->
             Connect.connect_tls ?host_eio ~alpn_protocols:[ "http/1.1" ] ?ca_file
               ~method_:request.method_ target tcp
             |> Effect.bind (fun (tls, _alpn) ->
                    request_on_flow ~max_response_body_bytes ~flow:(tls :> flow)
                      request))
