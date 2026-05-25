(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Eta

module Body = Eta_http_body.Stream
module Body_source = Eta_http_body.Source
module Chunked = Eta_http_body.Chunked
module Connect = Eta_http_transport.Connect
module Error = Eta_http_error.Error
module Header = Eta_http_core.Header
module Url = Eta_http_core.Url

type flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

type request_body =
  | Empty
  | Fixed of bytes list
  | Stream of Body.t
  | Rewindable_stream of {
      length : int option;
      make : unit -> Body.t;
    }

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
  trailers : unit -> (Header.t, Error.t) Effect.t;
}

type conn = {
  flow : flow;
  mutable used : bool;
  mutable reusable : bool;
  mutable last_used_ms : int;
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
  max_response_body_bytes : int;
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
  | Stream _ | Rewindable_stream _ -> Write.Empty

let request_body_source = function
  | Empty -> Body_source.Empty
  | Fixed chunks -> Body_source.Fixed chunks
  | Stream body -> Body_source.Stream body
  | Rewindable_stream { length; make } ->
      Body_source.Rewindable_stream { length; make }

let write_sync request f =
  Effect.sync (fun () ->
      try Ok (f ()) with _ -> Error (io_closed request Http_request))
  |> Effect.bind (function Ok value -> Effect.pure value | Error error -> Effect.fail error)

let write_bytes_effect request flow bytes =
  write_sync request (fun () ->
      Eio.Flow.copy_string (Bytes.to_string bytes) flow)

let write_string_effect request flow value =
  write_sync request (fun () -> Eio.Flow.copy_string value flow)

let transfer_encoding_chunked headers =
  match Header.get "transfer-encoding" headers with
  | None -> false
  | Some value ->
      value |> String.lowercase_ascii |> String.split_on_char ','
      |> List.exists (fun token -> String.equal (String.trim token) "chunked")

let write_raw_stream request flow body =
  let rec loop () =
    Body.read body
    |> Effect.bind (function
         | None -> Effect.unit
         | Some chunk -> write_bytes_effect request flow chunk |> Effect.bind loop)
  in
  loop ()

let write_chunked_stream request flow body =
  let rec loop () =
    Body.read body
    |> Effect.bind (function
         | None ->
             write_bytes_effect request flow (Chunked.encode_last_chunk ())
         | Some chunk ->
             Chunked.encode_chunk chunk
             |> List.map (write_bytes_effect request flow)
             |> Effect.concat
             |> Effect.bind loop)
  in
  loop ()

let stream_headers (request : request) length =
  let has_content_length = Option.is_some (Header.get "content-length" request.headers) in
  let has_transfer_encoding =
    Option.is_some (Header.get "transfer-encoding" request.headers)
  in
  match (length, has_content_length, has_transfer_encoding) with
  | Some length, false, false ->
      Header.unsafe_add "Content-Length" (string_of_int length) request.headers
  | None, false, false ->
      Header.unsafe_add "Transfer-Encoding" "chunked" request.headers
  | _ -> request.headers

let write_headers_effect request flow ~headers =
  Effect.sync (fun () ->
      try
        Write.write_to_flow flow ~method_:request.method_ ~url:request.url
          ~headers ~body:Write.Empty
      with _ -> Error (io_closed request Http_request))
  |> Effect.bind (function Ok () -> Effect.unit | Error error -> Effect.fail error)

let write_request flow (request : request) =
  Body_source.with_owned_stream (request_body_source request.body) (function
    | None ->
        Effect.sync (fun () ->
            try
              Write.write_to_flow flow ~method_:request.method_ ~url:request.url
                ~headers:request.headers ~body:(write_body request.body)
            with _ -> Error (io_closed request Http_request))
        |> Effect.bind (function
             | Ok () -> Effect.unit
             | Error error -> Effect.fail error)
    | Some { length; stream } ->
        let headers = stream_headers request length in
        write_headers_effect request flow ~headers
        |> Effect.bind (fun () ->
               if transfer_encoding_chunked headers then
                 write_chunked_stream request flow stream
               else write_raw_stream request flow stream))

let is_chunked headers =
  match Header.get "transfer-encoding" headers with
  | Some value ->
      value |> String.lowercase_ascii |> String.split_on_char ','
      |> List.exists (fun token -> String.equal (String.trim token) "chunked")
  | None -> false

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
let default_max_response_body_bytes = Body.default_max_bytes
let max_response_headers = 256
let response_chunk_size = 64 * 1024

let parse_error request error =
  protocol_violation request "parse" (Parse.parse_error_to_string error)

let body_too_large request ~limit ~length =
  make_error request (Body_too_large { limit; length })

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

type response_head = {
  status : int;
  headers : Header.t;
  content_length : int option;
  initial : bytes;
}

let read_response_head ?(initial = Bytes.empty) flow request =
  let buffer = Bytes.create max_header_bytes in
  let initial_len = Bytes.length initial in
  if initial_len > max_header_bytes then
    Error
      (parse_error request
         (Parse.Header_section_too_large { limit = max_header_bytes }))
  else (
    if initial_len > 0 then Bytes.blit initial 0 buffer 0 initial_len;
    let read_buffer = Cstruct.create max_header_bytes in
    let raw_headers = Parse.create_raw_headers max_response_headers in
    let raw = Parse.create_raw_response () in
    let rec loop used =
      match
        Parse.parse_raw buffer ~len:used ~max_header_bytes ~headers:raw_headers
          raw
      with
      | code when code = Parse.raw_ok || code = Parse.raw_body_truncated ->
          let body_off = Parse.raw_body_off raw in
          let available = max 0 (used - body_off) in
          let initial = Bytes.create available in
          if available > 0 then Bytes.blit buffer body_off initial 0 available;
          Ok
            {
              status = Parse.raw_status raw;
              headers =
                Header.unsafe_of_list
                  (Parse.raw_headers_to_list buffer raw_headers raw);
              content_length = Parse.raw_content_length raw;
              initial;
            }
      | code when code = Parse.raw_partial -> (
          match read_more flow read_buffer buffer used with
          | Ok used -> loop used
          | Error Parse.Partial -> Error (io_closed request Http_response)
          | Error error -> Error (parse_error request error))
      | code ->
          Error
            (parse_error request
               (Parse.raw_error buffer raw ~max_header_bytes code))
    in
    loop initial_len)

type body_source = {
  request : request;
  initial : bytes;
  mutable off : int;
  scratch : Cstruct.t;
  read_into : Cstruct.t -> int;
}

let make_body_source flow request initial =
  {
    request;
    initial;
    off = 0;
    scratch = Cstruct.create response_chunk_size;
    read_into = (fun buffer -> Eio.Flow.single_read flow buffer);
  }

let source_pending source = Bytes.length source.initial - source.off

let source_take_pending source n =
  let take = min n (source_pending source) in
  let chunk = Bytes.sub source.initial source.off take in
  source.off <- source.off + take;
  chunk

let source_read_some source max_len =
  Effect.sync (fun () ->
      if max_len <= 0 then None
      else if source_pending source > 0 then
        Some (source_take_pending source max_len)
      else
        let len = min max_len (Cstruct.length source.scratch) in
        try
          let read = source.read_into (Cstruct.sub source.scratch 0 len) in
          if read = 0 then None
          else
            let chunk = Bytes.create read in
            Cstruct.blit_to_bytes source.scratch 0 chunk 0 read;
            Some chunk
        with End_of_file -> None)

let source_read_exact source n =
  let out = Bytes.create n in
  let rec loop off remaining =
    if remaining = 0 then Effect.pure out
    else
      source_read_some source remaining
      |> Effect.bind (function
           | Some chunk ->
               let len = Bytes.length chunk in
               Bytes.blit chunk 0 out off len;
               loop (off + len) (remaining - len)
           | None -> Effect.fail (io_closed source.request Http_response))
  in
  loop 0 n

let source_read_line source ~limit =
  let buffer = Buffer.create 32 in
  let rec loop count previous_cr =
    if count > limit then
      Effect.fail
        (protocol_violation source.request "chunked"
           (Printf.sprintf "chunk line exceeds %d bytes" limit))
    else
      source_read_exact source 1
      |> Effect.bind (fun byte ->
             let c = Bytes.get byte 0 in
             if previous_cr && Char.equal c '\n' then (
               let len = Buffer.length buffer in
               let line = Buffer.contents buffer in
               Effect.pure (String.sub line 0 (len - 1)))
             else (
               Buffer.add_char buffer c;
               loop (count + 1) (Char.equal c '\r')))
  in
  loop 0 false

let fixed_body ~release source length =
  let remaining = ref length in
  let read_next () =
    if !remaining = 0 then Effect.pure Body.End
    else
      source_read_some source (min response_chunk_size !remaining)
      |> Effect.bind (function
           | None -> Effect.fail (io_closed source.request Http_response)
           | Some chunk ->
               let len = Bytes.length chunk in
               remaining := !remaining - len;
               if !remaining = 0 then Effect.pure (Body.Last chunk)
               else Effect.pure (Body.Chunk chunk))
  in
  Body.of_reader ~release read_next

let close_delimited_body ~max_response_body_bytes ~release source =
  let total = ref 0 in
  let read_next () =
    source_read_some source response_chunk_size
    |> Effect.bind (function
         | None -> Effect.pure Body.End
         | Some chunk ->
             let length = !total + Bytes.length chunk in
             if length < !total || length > max_response_body_bytes then
               Effect.fail
                 (body_too_large source.request ~limit:max_response_body_bytes
                    ~length)
             else (
               total := length;
               Effect.pure (Body.Chunk chunk)))
  in
  Body.of_reader ~release read_next

let chunked_body ~max_response_body_bytes ~release request source =
  let context =
    { Chunked.protocol = Error.H1; method_ = request.method_; uri = uri request }
  in
  let reader =
    {
      Chunked.read_exact = source_read_exact source;
      read_line = source_read_line source;
    }
  in
  let decoder =
    Chunked.create ~max_decoded_bytes:max_response_body_bytes ~context ~reader ()
  in
  let read_next () =
    Chunked.read decoder
    |> Effect.map (function None -> Body.End | Some chunk -> Body.Chunk chunk)
  in
  (Body.of_reader ~release read_next, fun () -> Effect.pure (Chunked.trailers decoder))

let response_body ~max_response_body_bytes ~release flow request
    (head : response_head) =
  let source = make_body_source flow request head.initial in
  if not (response_has_body request head.status) then
    (Body.of_bytes ~release [], fun () -> Effect.pure Header.empty)
  else if is_chunked head.headers then
    chunked_body ~max_response_body_bytes ~release request source
  else
    match head.content_length with
    | Some length ->
        if length > max_response_body_bytes then
          let body =
            Body.of_reader ~release (fun () ->
                Effect.fail
                  (body_too_large request ~limit:max_response_body_bytes ~length))
          in
          (body, fun () -> Effect.pure Header.empty)
        else (fixed_body ~release source length, fun () -> Effect.pure Header.empty)
    | None ->
        ( close_delimited_body ~max_response_body_bytes ~release source,
          fun () -> Effect.pure Header.empty )

let request_on_flow ?(max_response_body_bytes = default_max_response_body_bytes)
    ?release ~flow request =
  if max_response_body_bytes < 0 then
    invalid_arg
      "Eta_http.H1.Client.request_on_flow: max_response_body_bytes must be >= 0";
  let release = Option.value release ~default:(fun () -> close_flow request flow) in
  let release_on_error error =
    Effect.catch (fun _ -> Effect.unit) (release ())
    |> Effect.bind (fun () -> Effect.fail error)
  in
  write_request flow request
  |> Effect.catch release_on_error
  |> Effect.bind (fun () ->
         let rec read_final_response initial =
           Effect.sync (fun () -> read_response_head ~initial flow request)
           |> Effect.catch release_on_error
           |> Effect.bind (function
                | Error error -> release_on_error error
                | Ok head
                  when head.status >= 100 && head.status < 200
                       && head.status <> 101 ->
                    read_final_response head.initial
                | Ok head ->
                    let body, trailers =
                      response_body ~max_response_body_bytes ~release flow request
                        head
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

type release_ack = unit Channel.t
type cancel_signal = Cancel

let send_best_effort ch value =
  Channel.try_send ch value
  |> Effect.map (function `Sent | `Full | `Closed -> ())

let close_channel ch = Effect.sync (fun () -> Channel.close ch)

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

let open_conn ~sw ~net (target : Connect.target) =
  let wrap flow =
    { flow; used = false; reusable = true; last_used_ms = 0 }
  in
  Connect.connect_tcp ~sw ~net ~method_:"*" target
  |> Effect.bind (fun tcp ->
         match target.Connect.scheme with
         | Http -> Effect.pure (wrap (tcp :> flow))
         | Https ->
             Connect.connect_tls ~alpn_protocols:[ "http/1.1" ]
               ~method_:"*" target tcp
             |> Effect.map (fun (tls, _alpn) -> wrap (tls :> flow)))
  |> map_http_error

let make_pool ?(max_response_body_bytes = default_max_response_body_bytes)
    ?(max_size = 8) ?max_idle ?health_check ~sw ~net url =
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
          else health_check conn.flow |> map_http_error
    | None ->
        fun conn ->
          if not conn.reusable then
            Effect.fail (`Http (health_error target "connection marked unreusable"))
          else if not conn.used then Effect.unit
          else default_health_check target conn
  in
  Eta.Pool.create ~name:"eta-http.h1.pool" ~kind:"http.client" ~max_size
    ?max_idle ~acquire:(open_conn ~sw ~net target)
    ~release:close_conn ~health_check ()
  |> Effect.catch (fun err ->
         Effect.fail
           (pool_context_error ~method_:"*" ~uri:(Url.to_string url) err))
  |> Effect.map (fun pool -> { origin; target; max_response_body_bytes; pool })

let request_owner pool request response_ch release_ch cancel_ch =
  let ack = ref None in
  let report_error error = send_best_effort response_ch (Error error) in
  let hold_resource =
    Eta.Pool.with_resource pool.pool (fun conn ->
        let request_attempt =
          request_on_flow ~release:(fun () -> release_body release_ch)
            ~max_response_body_bytes:pool.max_response_body_bytes
            ~flow:conn.flow request
          |> Effect.map (fun response -> `Response response)
          |> Effect.catch (fun error -> Effect.pure (`Request_error error))
        in
        let cancel_wait =
          Channel.recv cancel_ch
          |> Effect.map (fun Cancel -> `Cancelled)
          |> Effect.catch (function `Closed -> Effect.pure `Cancelled)
        in
        Effect.race [ request_attempt; cancel_wait ]
        |> Effect.bind (function
             | `Request_error error ->
                 conn.reusable <- false;
                 Effect.fail (`Http error)
             | `Cancelled ->
                 conn.reusable <- false;
                 close_flow request conn.flow
                 |> Effect.catch (fun _ -> Effect.unit)
                 |> Effect.bind (fun () ->
                        Effect.fail (`Http (io_closed request Cancellation)))
             | `Response (response : response) ->
                 conn.used <- true;
                 conn.last_used_ms <- int_of_float (Unix.gettimeofday () *. 1000.0);
                 if connection_close_requested response.headers then
                   conn.reusable <- false;
                 Channel.try_send response_ch (Ok response)
                 |> Effect.bind (function
                      | `Sent ->
                          Channel.recv release_ch
                          |> Effect.map (fun release_ack ->
                               ack := Some release_ack)
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
             Effect.Private.daemon
               (request_owner pool request response_ch release_ch cancel_ch)
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

let request ?(max_response_body_bytes = default_max_response_body_bytes) ~sw ~net
    request =
  if max_response_body_bytes < 0 then
    invalid_arg "Eta_http.H1.Client.request: max_response_body_bytes must be >= 0";
  let target = Connect.target_of_url request.url in
  Connect.connect_tcp ~sw ~net ~method_:request.method_ target
  |> Effect.bind (fun tcp ->
         match target.scheme with
         | Http -> request_on_flow ~max_response_body_bytes ~flow:tcp request
         | Https ->
             Connect.connect_tls ~alpn_protocols:[ "http/1.1" ]
               ~method_:request.method_ target tcp
             |> Effect.bind (fun (tls, _alpn) ->
                    request_on_flow ~max_response_body_bytes ~flow:(tls :> flow)
                      request))
