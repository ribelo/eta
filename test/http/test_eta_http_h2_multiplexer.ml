open Test_eta_http_support
open Test_eta_http_h2_support

let test_h2_multiplexer_reads_server_response () =
  let result = h2_read_result () in
  let server =
    H2.Server_connection.create
      ~error_handler:(fun ?request:_ _ respond ->
        result.stream_errors <- result.stream_errors + 1;
        let body = respond H2.Headers.empty in
        H2.Body.Writer.close body)
      (fun reqd ->
        H2.Reqd.respond_with_string reqd (H2.Response.create `OK) "hello-read")
  in
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> result.client_errors <- result.client_errors + 1)
      ()
  in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/reader"
  in
  let request_body =
    H2.Client_connection.request client request
      ~error_handler:(fun _ -> result.stream_errors <- result.stream_errors + 1)
      ~response_handler:(fun response body ->
        result.status <- Some (H2.Status.to_code response.status);
        h2_schedule_body result body)
  in
  H2.Body.Writer.close request_body;
  let request_bytes = Buffer.create 256 in
  let request_flow = Eio.Flow.buffer_sink request_bytes in
  (match Eta_http.H2.Writer.drain_client ~flow:request_flow client with
  | Yield _ -> ()
  | Close { code; _ } -> Alcotest.failf "unexpected client writer close=%d" code);
  h2_feed_server server (Buffer.contents request_bytes);
  let response_bytes = h2_drain_server_output server [] in
  let source =
    Eio.Flow.cstruct_source (h2_cstruct_chunks ~chunk_size:7 response_bytes)
  in
  let reader = Eta_http.H2.Multiplexer.create_client_reader ~buffer_size:128 client in
  let rec loop reads =
    if reads > 100 then Alcotest.fail "h2 reader did not deliver response"
    else if result.eof then ()
    else
      match Eta_http.H2.Multiplexer.read_client_once ~flow:source reader with
      | Read _ -> loop (reads + 1)
      | Eof _ -> loop (reads + 1)
      | Security_error kind ->
          Alcotest.failf "unexpected h2 security error: %s"
            (Eta_http.Error.kind_name kind)
      | Close -> Alcotest.fail "client reader closed before response EOF"
  in
  loop 0;
  Alcotest.(check (option int)) "status" (Some 200) result.status;
  Alcotest.(check string) "body" "hello-read" (Buffer.contents result.body);
  Alcotest.(check int) "client errors" 0 result.client_errors;
  Alcotest.(check int) "stream errors" 0 result.stream_errors

let h2_opened label = function
  | Ok opened -> opened
  | Error `Admission_rejected -> Alcotest.failf "%s rejected by admission" label
  | Error `Connection_closed -> Alcotest.failf "%s rejected by closed connection" label
  | Error (`Request_failed message) ->
      Alcotest.failf "%s failed before open: %s" label message

let h2_stream_of_result label result =
  match result.mux_stream with
  | Some stream -> stream
  | None -> Alcotest.failf "%s did not record stream" label

let h2_response_body label = function
  | Some body -> body
  | None -> Alcotest.failf "%s did not receive response body" label

let h2_response_writer label = function
  | Some body -> body
  | None -> Alcotest.failf "%s did not install response writer" label

let test_h2_default_reader_accepts_max_sized_data_frame () =
  let payload = String.make (16 * 1024) 'x' in
  let result = h2_read_result () in
  let server =
    H2.Server_connection.create (fun reqd ->
        H2.Reqd.respond_with_string reqd (H2.Response.create `OK) payload)
  in
  let client =
    H2.Client_connection.create
      ~error_handler:(fun _ -> result.client_errors <- result.client_errors + 1)
      ()
  in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/max-data"
  in
  let request_body =
    H2.Client_connection.request client request
      ~error_handler:(fun _ -> result.stream_errors <- result.stream_errors + 1)
      ~response_handler:(fun response body ->
        result.status <- Some (H2.Status.to_code response.status);
        h2_schedule_body result body)
  in
  H2.Body.Writer.close request_body;
  let request_bytes = Buffer.create 256 in
  let request_flow = Eio.Flow.buffer_sink request_bytes in
  (match Eta_http.H2.Writer.drain_client ~flow:request_flow client with
  | Yield _ -> ()
  | Close { code; _ } -> Alcotest.failf "unexpected client writer close=%d" code);
  h2_feed_server server (Buffer.contents request_bytes);
  let response_bytes = h2_drain_server_output server [] in
  let source =
    Eio.Flow.cstruct_source
      (h2_cstruct_chunks ~chunk_size:(String.length response_bytes) response_bytes)
  in
  let reader = Eta_http.H2.Multiplexer.create_client_reader client in
  let rec loop reads =
    if reads > 100 then Alcotest.fail "h2 reader did not deliver max DATA frame"
    else if result.eof then ()
    else
      match Eta_http.H2.Multiplexer.read_client_once ~flow:source reader with
      | Read _ | Eof _ -> loop (reads + 1)
      | Security_error kind ->
          Alcotest.failf "unexpected h2 security error: %s"
            (Eta_http.Error.kind_name kind)
      | Close -> Alcotest.fail "client reader closed before max DATA EOF"
  in
  loop 0;
  Alcotest.(check (option int)) "status" (Some 200) result.status;
  Alcotest.(check int) "body bytes" (String.length payload)
    (Buffer.length result.body);
  Alcotest.(check string) "body" payload (Buffer.contents result.body);
  Alcotest.(check int) "client errors" 0 result.client_errors;
  Alcotest.(check int) "stream errors" 0 result.stream_errors

let test_h2_request_exception_releases_admission () =
  let mux = Eta_http.H2.Multiplexer.create ~max_concurrent:1 () in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/raises"
  in
  let raising_request _client ?trailers_handler:_ _request ~error_handler:_
      ~response_handler:_ =
    raise (Failure "synthetic h2 request failure")
  in
  let open_bad tag =
    Eta_http.H2.Multiplexer.For_test.request_with_h2_request raising_request mux
      ~tag request
      ~error_handler:(fun _ _ -> ())
      ~response_handler:(fun _ _ _ -> ())
  in
  let expect_request_failed label = function
    | Error (Eta_http.H2.Multiplexer.Request_failed _) -> ()
    | Error (Eta_http.H2.Multiplexer.Admission_rejected _) ->
        Alcotest.failf "%s leaked admission permit" label
    | Error Eta_http.H2.Multiplexer.Connection_closed ->
        Alcotest.failf "%s saw unexpected closed connection" label
    | Ok _ -> Alcotest.failf "%s unexpectedly opened stream" label
  in
  expect_request_failed "first request" (open_bad 1);
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active after exception" 0 stats.active;
  Alcotest.(check int) "live after exception" 0 stats.live;
  expect_request_failed "second request" (open_bad 2);
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active after second exception" 0 stats.active;
  Alcotest.(check int) "live after second exception" 0 stats.live

let h2_body_pump_effect client server =
  Eta.Effect.sync (fun () ->
      let client_progress = h2_drain_client_to_server client server in
      let server_progress = h2_drain_server_to_client server client in
      if client_progress || server_progress then Eta_http.H2.Multiplexer.Read 1
      else Eta_http.H2.Multiplexer.Eof 0)

let h2_body_closed_error =
  Eta_http.Error.make ~protocol:H2 ~method_:"GET" ~uri:"https://api.example.test/"
    (Connection_closed { during = Http_response })

let h2_open_streaming_body mux client server held_writer body_ref =
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/stream"
  in
  let opened =
    Eta_http.H2.Multiplexer.request mux ~tag:1 request
      ~error_handler:(fun _ error ->
        Alcotest.failf "unexpected h2 stream error: %s"
          (h2_pp_client_error error))
      ~response_handler:(fun stream response body ->
        Alcotest.(check int) "status" 200 (H2.Status.to_code response.status);
        body_ref :=
          Some
            (Eta_http.H2.Multiplexer.body_stream
               ~closed_error:h2_body_closed_error
               ~pump:(fun () -> h2_body_pump_effect client server)
               mux stream body))
  in
  let opened =
    match opened with
    | Ok opened -> opened
    | Error (Eta_http.H2.Multiplexer.Admission_rejected _) ->
        Alcotest.fail "streaming body rejected by admission"
    | Error Eta_http.H2.Multiplexer.Connection_closed ->
        Alcotest.fail "streaming body saw closed connection"
    | Error (Eta_http.H2.Multiplexer.Request_failed message) ->
        Alcotest.failf "streaming body request failed: %s" message
  in
  H2.Body.Writer.close opened.request_body;
  h2_pump_pair client server;
  h2_response_writer "streaming body" !held_writer

let test_h2_body_stream_releases_on_eof () =
  let held_writer = ref None in
  let server =
    H2.Server_connection.create (fun reqd ->
        held_writer :=
          Some (H2.Reqd.respond_with_streaming reqd (H2.Response.create `OK)))
  in
  let mux = h2_mux_create (h2_mux_result ()) () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let body_ref = ref None in
  let writer = h2_open_streaming_body mux client server held_writer body_ref in
  H2.Body.Writer.write_string writer "hello";
  H2.Body.Writer.close writer;
  with_test_clock @@ fun _sw _clock rt ->
  let body =
    Eta_http.Body.Stream.read_all (h2_response_body "eof" !body_ref)
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello" (Bytes.to_string body);
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active" 0 stats.active;
  Alcotest.(check int) "live" 0 stats.live;
  Alcotest.(check int) "completed" 1 stats.completed;
  Alcotest.(check int) "local resets" 0 stats.local_resets

let test_h2_body_stream_reads_inline_data_after_header_pump () =
  let body_ref = ref None in
  let server =
    H2.Server_connection.create (fun reqd ->
        H2.Reqd.respond_with_string reqd (H2.Response.create `Not_found)
          "hello-inline")
  in
  let mux = h2_mux_create (h2_mux_result ()) () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/inline"
  in
  let opened =
    Eta_http.H2.Multiplexer.request mux ~tag:1 request
      ~error_handler:(fun _ error ->
        Alcotest.failf "unexpected h2 stream error: %s"
          (h2_pp_client_error error))
      ~response_handler:(fun stream response body ->
        Alcotest.(check int) "status" 404 (H2.Status.to_code response.status);
        body_ref :=
          Some
            (Eta_http.H2.Multiplexer.body_stream
               ~closed_error:h2_body_closed_error
               ~pump:(fun () -> h2_body_pump_effect client server)
               mux stream body))
  in
  let opened =
    match opened with
    | Ok opened -> opened
    | Error (Eta_http.H2.Multiplexer.Admission_rejected _) ->
        Alcotest.fail "inline body rejected by admission"
    | Error Eta_http.H2.Multiplexer.Connection_closed ->
        Alcotest.fail "inline body saw closed connection"
    | Error (Eta_http.H2.Multiplexer.Request_failed message) ->
        Alcotest.failf "inline body request failed: %s" message
  in
  H2.Body.Writer.close opened.request_body;
  h2_pump_pair client server;
  with_test_clock @@ fun _sw _clock rt ->
  let body =
    Eta_http.Body.Stream.read_all (h2_response_body "inline" !body_ref)
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello-inline" (Bytes.to_string body);
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active" 0 stats.active;
  Alcotest.(check int) "completed" 1 stats.completed

let test_h2_multiplexer_delivers_response_trailers () =
  let body_ref = ref None in
  let trailers_ref = ref None in
  let server =
    H2.Server_connection.create (fun reqd ->
        let response_body =
          H2.Reqd.respond_with_streaming reqd
            (H2.Response.create
               ~headers:(H2.Headers.of_list [ "content-type", "application/grpc+proto" ])
               `OK)
        in
        H2.Body.Writer.write_string response_body "\000\000\000\000\005hello";
        H2.Reqd.schedule_trailers reqd
          (H2.Headers.of_list [ "grpc-status", "0"; "grpc-message", "" ]);
        H2.Body.Writer.close response_body)
  in
  let mux = h2_mux_create (h2_mux_result ()) () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `POST "/grpc.Service/Unary"
  in
  let opened =
    Eta_http.H2.Multiplexer.request mux ~tag:1
      ~trailers_handler:(fun trailers ->
        trailers_ref := Some (H2.Headers.to_list trailers))
      request
      ~error_handler:(fun _ error ->
        Alcotest.failf "unexpected h2 stream error: %s"
          (h2_pp_client_error error))
      ~response_handler:(fun stream response body ->
        Alcotest.(check int) "status" 200 (H2.Status.to_code response.status);
        body_ref :=
          Some
            (Eta_http.H2.Multiplexer.body_stream
               ~closed_error:h2_body_closed_error
               ~pump:(fun () -> h2_body_pump_effect client server)
               mux stream body))
  in
  let opened =
    match opened with
    | Ok opened -> opened
    | Error (Eta_http.H2.Multiplexer.Admission_rejected _) ->
        Alcotest.fail "trailers request rejected by admission"
    | Error Eta_http.H2.Multiplexer.Connection_closed ->
        Alcotest.fail "trailers request saw closed connection"
    | Error (Eta_http.H2.Multiplexer.Request_failed message) ->
        Alcotest.failf "trailers request failed: %s" message
  in
  H2.Body.Writer.close opened.request_body;
  h2_pump_pair client server;
  let early_trailers =
    match !trailers_ref with
    | Some trailers -> trailers
    | None -> Alcotest.fail "trailers were not delivered by END_STREAM"
  in
  with_test_clock @@ fun _sw _clock rt ->
  let body =
    Eta_http.Body.Stream.read_all (h2_response_body "trailers" !body_ref)
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "raw grpc body" "\000\000\000\000\005hello"
    (Bytes.to_string body);
  Alcotest.(check (option string)) "grpc status" (Some "0")
    (Eta_http.Core.Header.get "grpc-status" early_trailers);
  Alcotest.(check (option string)) "grpc message" (Some "")
    (Eta_http.Core.Header.get "grpc-message" early_trailers)

let test_h2_body_stream_discard_releases_active_stream () =
  let held_writer = ref None in
  let server =
    H2.Server_connection.create (fun reqd ->
        held_writer :=
          Some (H2.Reqd.respond_with_streaming reqd (H2.Response.create `OK)))
  in
  let mux = h2_mux_create (h2_mux_result ()) () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let body_ref = ref None in
  let writer = h2_open_streaming_body mux client server held_writer body_ref in
  H2.Body.Writer.write_string writer "prefix";
  with_test_clock @@ fun _sw _clock rt ->
  let body = h2_response_body "discard" !body_ref in
  let chunk =
    Eta_http.Body.Stream.read body |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check (option string)) "first chunk" (Some "prefix")
    (Option.map Bytes.to_string chunk);
  Eta_http.Body.Stream.discard body |> Eta.Runtime.run rt
  |> Eta_test.Expect.expect_ok;
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active" 0 stats.active;
  Alcotest.(check int) "live" 0 stats.live;
  Alcotest.(check int) "local reset" 1 stats.local_resets

let test_h2_multiplexer_sustains_100_concurrent_gets () =
  let connection_result = h2_mux_result () in
  let server =
    H2.Server_connection.create (fun reqd ->
        let target = (H2.Reqd.request reqd).target in
        H2.Reqd.respond_with_string reqd (H2.Response.create `OK)
          ("get:" ^ target))
  in
  let mux = h2_mux_create connection_result () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let results = List.init 100 (fun _ -> h2_mux_result ()) in
  List.iteri
    (fun i result ->
      ignore
        (h2_opened "concurrent GET"
           (h2_open_mux_request ~tag:i
              ~target:(Printf.sprintf "/concurrent/%d" i)
              mux result)))
    results;
  h2_pump_pair client server;
  List.iteri
    (fun i result ->
      Alcotest.(check (option int)) "status" (Some 200) result.mux_status;
      Alcotest.(check string) "body"
        (Printf.sprintf "get:/concurrent/%d" i)
        (Buffer.contents result.mux_body);
      Alcotest.(check bool) "eof" true result.mux_eof;
      Alcotest.(check int) "stream errors" 0
        (List.length result.mux_stream_errors);
      Alcotest.(check bool) "release complete" true
        (Eta_http.H2.Multiplexer.release mux
           (h2_stream_of_result "concurrent GET" result)
        = Eta_http.H2.Stream_state.No_rst))
    results;
  Alcotest.(check int) "connection errors" 0
    (List.length connection_result.mux_client_errors);
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active" 0 stats.active;
  Alcotest.(check int) "cancelled" 0 stats.cancelled;
  Alcotest.(check int) "live" 0 stats.live;
  Alcotest.(check int) "opened" 100 stats.opened;
  Alcotest.(check int) "completed" 100 stats.completed;
  Alcotest.(check int) "max inflight" 100 stats.max_inflight

let test_h2_multiplexer_upload_flow_control_resumes () =
  let connection_result = h2_mux_result () in
  let held = ref None in
  let server =
    H2.Server_connection.create (fun reqd ->
        match (H2.Reqd.request reqd).meth, (H2.Reqd.request reqd).target with
        | `POST, "/upload-hold" -> held := Some reqd
        | _ ->
            H2.Reqd.respond_with_string reqd (H2.Response.create `OK)
              "unexpected")
  in
  let mux = h2_mux_create connection_result () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let result = h2_mux_result () in
  let payload = String.make (128 * 1024) 'x' in
  ignore
    (h2_opened "upload"
       (h2_open_mux_request ~meth:`POST ~body:payload ~target:"/upload-hold"
          mux result));
  h2_pump_pair client server;
  Alcotest.(check (option int)) "no response before server body read" None
    result.mux_status;
  let reqd =
    match !held with
    | Some reqd -> reqd
    | None -> Alcotest.fail "server did not hold upload request"
  in
  h2_server_read_body reqd ~on_done:(fun body ->
      H2.Reqd.respond_with_string reqd (H2.Response.create `OK)
        (Printf.sprintf "upload:%d" (String.length body)));
  h2_pump_pair client server;
  Alcotest.(check (option int)) "status" (Some 200) result.mux_status;
  Alcotest.(check string) "body" "upload:131072"
    (Buffer.contents result.mux_body);
  Alcotest.(check bool) "eof" true result.mux_eof;
  Alcotest.(check bool) "release complete" true
    (Eta_http.H2.Multiplexer.release mux
       (h2_stream_of_result "upload" result)
    = Eta_http.H2.Stream_state.No_rst);
  Alcotest.(check int) "connection errors" 0
    (List.length connection_result.mux_client_errors)

let test_h2_multiplexer_server_reset_admission_release () =
  let connection_result = h2_mux_result () in
  let server =
    H2.Server_connection.create (fun reqd ->
        let body =
          H2.Reqd.respond_with_streaming reqd (H2.Response.create `OK)
        in
        H2.Body.Writer.write_string body "partial";
        H2.Reqd.report_exn reqd (Failure "reset-fixture"))
  in
  let mux = h2_mux_create ~max_concurrent:32 connection_result () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let results = List.init 32 (fun _ -> h2_mux_result ()) in
  List.iteri
    (fun i result ->
      ignore
        (h2_opened "reset"
           (h2_open_mux_request ~tag:i ~target:"/rst" mux result)))
    results;
  h2_pump_pair client server;
  List.iter
    (fun result ->
      Alcotest.(check bool) "stream error observed" true
        (List.length result.mux_stream_errors > 0))
    results;
  let stats_after_reset = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active after reset" 0 stats_after_reset.active;
  Alcotest.(check int) "cancelled after reset" 32 stats_after_reset.cancelled;
  Alcotest.(check int) "live after reset" 32 stats_after_reset.live;
  Alcotest.(check int) "remote resets" 32 stats_after_reset.remote_resets;
  let rejected =
    List.init 100 (fun i ->
        let result = h2_mux_result () in
        match h2_open_mux_request ~tag:(1000 + i) ~target:"/rst" mux result with
        | Error `Admission_rejected -> 1
        | Error `Connection_closed -> Alcotest.fail "connection closed"
        | Error (`Request_failed message) ->
            Alcotest.failf "request failed: %s" message
        | Ok _ -> Alcotest.fail "cancelled streams should still occupy admission")
    |> List.fold_left ( + ) 0
  in
  Alcotest.(check int) "rejected while cancelled admitted" 100 rejected;
  List.iter
    (fun result ->
      Alcotest.(check bool) "remote reset release" true
        (Eta_http.H2.Multiplexer.release mux
           (h2_stream_of_result "reset" result)
        = Eta_http.H2.Stream_state.No_rst))
    results;
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active final" 0 stats.active;
  Alcotest.(check int) "cancelled final" 0 stats.cancelled;
  Alcotest.(check int) "live final" 0 stats.live;
  Alcotest.(check int) "completed" 32 stats.completed;
  Alcotest.(check int) "admission rejected" 100 stats.admission_rejected;
  Alcotest.(check int) "max inflight" 32 stats.max_inflight;
  Alcotest.(check int) "connection errors" 0
    (List.length connection_result.mux_client_errors)

let test_h2_multiplexer_client_cancel_releases_stream () =
  let connection_result = h2_mux_result () in
  let server =
    H2.Server_connection.create (fun reqd ->
        match (H2.Reqd.request reqd).target with
        | "/slow" ->
            let body =
              H2.Reqd.respond_with_streaming reqd (H2.Response.create `OK)
            in
            H2.Body.Writer.write_string body "slow-prefix"
        | target ->
            H2.Reqd.respond_with_string reqd (H2.Response.create `OK)
              ("get:" ^ target))
  in
  let mux = h2_mux_create connection_result () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let first = h2_mux_result () in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/slow"
  in
  let opened =
    match
      Eta_http.H2.Multiplexer.request mux ~tag:1 request
        ~error_handler:(fun stream error ->
          first.mux_stream <- Some stream;
          first.mux_stream_errors <-
            h2_pp_client_error error :: first.mux_stream_errors)
        ~response_handler:(fun stream response response_body ->
          first.mux_stream <- Some stream;
          first.mux_status <- Some (H2.Status.to_code response.status);
          H2.Body.Reader.schedule_read response_body
            ~on_eof:(fun () -> Alcotest.fail "slow response ended early")
            ~on_read:(fun bs ~off ~len ->
              Buffer.add_string first.mux_body
                (Bigstringaf.substring bs ~off ~len);
              first.mux_release <-
                Some (Eta_http.H2.Multiplexer.release mux stream)))
    with
    | Ok opened -> opened
    | Error (Eta_http.H2.Multiplexer.Admission_rejected _) ->
        Alcotest.fail "slow request rejected"
    | Error Eta_http.H2.Multiplexer.Connection_closed ->
        Alcotest.fail "slow request saw closed connection"
    | Error (Eta_http.H2.Multiplexer.Request_failed message) ->
        Alcotest.failf "slow request failed: %s" message
  in
  H2.Body.Writer.close opened.request_body;
  h2_pump_pair client server;
  Alcotest.(check (option int)) "slow status" (Some 200) first.mux_status;
  Alcotest.(check string) "first chunk" "slow-prefix"
    (Buffer.contents first.mux_body);
  Alcotest.(check bool) "released active stream" true
    (first.mux_release = Some Eta_http.H2.Stream_state.Queue_rst);
  let after = h2_mux_result () in
  ignore
    (h2_opened "after cancel"
       (h2_open_mux_request ~tag:2 ~target:"/after-cancel" mux after));
  h2_pump_pair client server;
  Alcotest.(check (option int)) "after status" (Some 200) after.mux_status;
  Alcotest.(check string) "after body" "get:/after-cancel"
    (Buffer.contents after.mux_body);
  Alcotest.(check bool) "after release" true
    (Eta_http.H2.Multiplexer.release mux
       (h2_stream_of_result "after cancel" after)
    = Eta_http.H2.Stream_state.No_rst);
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "active final" 0 stats.active;
  Alcotest.(check int) "live final" 0 stats.live;
  Alcotest.(check int) "local resets" 1 stats.local_resets;
  Alcotest.(check int) "connection errors" 0
    (List.length connection_result.mux_client_errors)


let rec h2_drain_client_writes client =
  match H2.Client_connection.next_write_operation client with
  | `Write iovecs ->
      let data = h2_iovecs_to_string iovecs in
      H2.Client_connection.report_write_result client (`Ok (String.length data));
      1 + h2_drain_client_writes client
  | `Yield -> 0
  | `Close _ ->
      H2.Client_connection.report_write_result client `Closed;
      0

let test_h2_multiplexer_rejects_after_goaway () =
  let connection_result = h2_mux_result () in
  let mux = h2_mux_create connection_result () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let first = h2_mux_result () in
  ignore
    (h2_opened "before GOAWAY"
       (h2_open_mux_request ~tag:1 ~target:"/before-goaway" mux first));
  ignore (h2_drain_client_writes client);
  h2_feed_client client (h2_settings_frame ^ h2_goaway_no_error ~last_stream_id:1);
  Alcotest.(check bool) "open before GOAWAY flush" false
    (H2.Client_connection.is_closed client);
  ignore (h2_drain_client_writes client);
  Alcotest.(check bool) "closed after GOAWAY flush" true
    (H2.Client_connection.is_closed client);
  let after = h2_mux_result () in
  (match h2_open_mux_request ~tag:2 ~target:"/after-goaway" mux after with
  | Error `Connection_closed -> ()
  | Error `Admission_rejected -> Alcotest.fail "GOAWAY reported as admission pressure"
  | Error (`Request_failed message) ->
      Alcotest.failf "GOAWAY request failed: %s" message
  | Ok _ -> Alcotest.fail "post-GOAWAY request was admitted");
  let stats = Eta_http.H2.Multiplexer.stats mux in
  Alcotest.(check int) "opened before only" 1 stats.opened;
  Alcotest.(check int) "no admission pressure" 0 stats.admission_rejected

(* P0: body_stream_async unbounded recursion when h2 fires on_read synchronously.
   When many DATA frames are pre-buffered into the h2 client connection before
   the response body consumer reads, schedule_read's on_read callback calls
   schedule_read() again. If h2 delivers data synchronously (already buffered),
   this creates recursion proportional to the number of buffered chunks.
   With a large response this causes stack overflow or unbounded queue growth. *)
let test_h2_body_stream_async_bounded_recursion () =
  (* Generate a response large enough that many on_read callbacks would fire
     if schedule_read recursed unboundedly. With OCaml's default 8MB stack,
     ~8000 recursive frames would overflow. We use 2000 chunks of 1KB
     to be in the danger zone. *)
  let num_chunks = 2000 in
  let chunk_data = String.make 1024 'x' in
  let total_size = num_chunks * String.length chunk_data in
  let h2_config =
    {
      H2.Config.default with
      response_body_buffer_size = total_size;
      initial_window_size = Int32.of_int (total_size * 2);
    }
  in
  let held_writer = ref None in
  let server =
    H2.Server_connection.create ~config:h2_config (fun reqd ->
        held_writer :=
          Some (H2.Reqd.respond_with_streaming reqd (H2.Response.create `OK)))
  in
  let mux = h2_mux_create ~config:h2_config (h2_mux_result ()) () in
  let client = Eta_http.H2.Multiplexer.client_connection mux in
  let body_stream_ref = ref None in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/large-buffered"
  in
  let opened =
    Eta_http.H2.Multiplexer.request mux ~tag:1 request
      ~error_handler:(fun _stream _error -> ())
      ~response_handler:(fun stream _response body ->
        let stream_and_notify =
          Eta_http.H2.Multiplexer.body_stream_async
            ~closed_error:h2_body_closed_error mux stream body
        in
        body_stream_ref := Some stream_and_notify)
  in
  let opened =
    match opened with
    | Ok opened -> opened
    | Error _ -> Alcotest.fail "request setup failed"
  in
  H2.Body.Writer.close opened.request_body;
  (* Pump the request to the server and get response headers *)
  h2_pump_pair client server;
  (* Write all chunks to the server writer and close *)
  let writer = match !held_writer with
    | Some w -> w
    | None -> Alcotest.fail "server did not install streaming writer"
  in
  for _ = 1 to num_chunks do
    H2.Body.Writer.write_string writer chunk_data
  done;
  H2.Body.Writer.close writer;
  (* Pump currently writable server output to the client before consuming the
     body stream. The consumer below keeps pumping as flow-control windows are
     returned, while the already-buffered frame still exercises synchronous
     on_read delivery. *)
  h2_pump_pair client server;
  (* At this point, response_handler has already been called and
     body_stream_async has seen a buffered DATA frame. If synchronous on_read
     scheduling is recursive, a large response can still overflow while the
     read loop below drains the rest. *)
  match !body_stream_ref with
  | None ->
      (* Response headers didn't arrive - pump again for test robustness *)
      Alcotest.fail "body_stream_async was never created (response headers missing)"
  | Some (body_stream, notify) ->
      (* Wake the stream reader to process events *)
      notify ();
      with_test_clock @@ fun sw _clock rt ->
      let done_reading = ref false in
      Eio.Fiber.fork ~sw (fun () ->
          while not !done_reading do
            h2_pump_pair client server;
            Eio.Fiber.yield ()
          done);
      let total_bytes = ref 0 in
      let read_all =
        Eta_http.Body.Stream.read_all ~max_bytes:total_size body_stream
        |> Eta.Effect.map (fun bytes -> total_bytes := Bytes.length bytes)
      in
      let result =
        Fun.protect
          ~finally:(fun () -> done_reading := true)
          (fun () -> Eta.Runtime.run rt read_all)
      in
      (match result with
      | Eta.Exit.Ok () ->
          (* If we got here, the recursion didn't cause a stack overflow.
             Verify the body stream delivered the buffered frame without
             recursively draining the whole response into its OCaml queue. *)
          Alcotest.(check int) "buffered bytes" H2.Settings.default.max_frame_size
            !total_bytes
      | Eta.Exit.Error _ ->
          (* The stream returned an error - this demonstrates that pre-buffered
             data combined with body_stream_async's recursive schedule_read
             causes incorrect behavior (either the reader gets confused,
             or data is lost, or the queue overflows). *)
          Alcotest.fail
            "body_stream_async failed to deliver pre-buffered response body \
             (recursive schedule_read likely corrupted internal state)")
