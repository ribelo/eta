open Test_eta_http_support
open Test_eta_http_h2_support

let hpack_header name value = { Hpack.name; value; sensitive = false }

let hpack_block encoder headers =
  let faraday = Faraday.create 0x1000 in
  List.iter (Hpack.Encoder.encode_header encoder faraday) headers;
  Faraday.serialize_to_string faraday

let raw_headers encoder ?(end_stream = false) ~stream_id headers =
  let block = hpack_block encoder headers in
  let flags = 0x4 lor (if end_stream then 0x1 else 0) in
  Eta_http.H2.Frame.header ~length:(String.length block)
    ~frame_type:Eta_http.H2.Frame.Headers ~flags ~stream_id
  ^ block

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
  (match Eta_http_eio.H2.Writer.drain_client ~flow:request_flow client with
  | Yield _ -> ()
  | Close { code; _ } -> Alcotest.failf "unexpected client writer close=%d" code);
  h2_feed_server server (Buffer.contents request_bytes);
  let response_bytes = h2_drain_server_output server [] in
  let source =
    Eio.Flow.cstruct_source (h2_cstruct_chunks ~chunk_size:7 response_bytes)
  in
  let reader = Eta_http_eio.H2.Multiplexer.create_client_reader ~buffer_size:128 client in
  let rec loop reads =
    if reads > 100 then Alcotest.fail "h2 reader did not deliver response"
    else if result.eof then ()
    else
      match Eta_http_eio.H2.Multiplexer.read_client_once ~flow:source reader with
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

let test_h2_multiplexer_read_exception_is_typed_result () =
  let client = H2.Client_connection.create ~error_handler:(fun _ -> ()) () in
  let reader = Eta_http_eio.H2.Multiplexer.create_client_reader client in
  let flow = Eio_mock.Flow.make "eta-http-h2-read-raises" in
  Eio_mock.Flow.on_read flow [ `Raise (Failure "h2 socket boom") ];
  match Eta_http_eio.H2.Multiplexer.read_client_once ~flow reader with
  | Eta_http_eio.H2.Multiplexer.Security_error
      (Eta_http.Error.Connection_closed { during = Eta_http.Error.Http_response })
    ->
      ()
  | Eta_http_eio.H2.Multiplexer.Security_error
      (Eta_http.Error.Connection_protocol_violation { kind = "h2_read"; _ }) ->
      ()
  | Eta_http_eio.H2.Multiplexer.Security_error kind ->
      Alcotest.failf "unexpected typed read error kind: %s"
        (Eta_http.Error.kind_name kind)
  | Eta_http_eio.H2.Multiplexer.Read _ | Eta_http_eio.H2.Multiplexer.Eof _
  | Eta_http_eio.H2.Multiplexer.Close ->
      Alcotest.fail "read exception was not reported as a typed read error"

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
  (match Eta_http_eio.H2.Writer.drain_client ~flow:request_flow client with
  | Yield _ -> ()
  | Close { code; _ } -> Alcotest.failf "unexpected client writer close=%d" code);
  h2_feed_server server (Buffer.contents request_bytes);
  let response_bytes = h2_drain_server_output server [] in
  let source =
    Eio.Flow.cstruct_source
      (h2_cstruct_chunks ~chunk_size:(String.length response_bytes) response_bytes)
  in
  let reader = Eta_http_eio.H2.Multiplexer.create_client_reader client in
  let rec loop reads =
    if reads > 100 then Alcotest.fail "h2 reader did not deliver max DATA frame"
    else if result.eof then ()
    else
      match Eta_http_eio.H2.Multiplexer.read_client_once ~flow:source reader with
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

let test_h2_multiplexer_release_forgets_informational_filter_stream () =
  let mux = Eta_http_eio.H2.Multiplexer.create () in
  let reader = Eta_http_eio.H2.Multiplexer.create_reader mux in
  let status = ref None in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/filtered-release"
  in
  let opened =
    match
      Eta_http_eio.H2.Multiplexer.request mux ~tag:1 request
        ~error_handler:(fun _ _ -> Alcotest.fail "unexpected stream error")
        ~response_handler:(fun _stream response _body ->
          status := Some (H2.Status.to_code response.status))
    with
    | Ok opened -> opened
    | Error (Eta_http_eio.H2.Multiplexer.Admission_rejected _) ->
        Alcotest.fail "unexpected admission rejection"
    | Error Eta_http_eio.H2.Multiplexer.Connection_closed ->
        Alcotest.fail "unexpected closed mux"
    | Error (Eta_http_eio.H2.Multiplexer.Request_failed message) ->
        Alcotest.failf "unexpected request failure: %s" message
  in
  H2.Body.Writer.close opened.request_body;
  let stream_id = Eta_http.H2.Stream_state.id opened.stream in
  let encoder = Hpack.Encoder.create 4096 in
  let source =
    Eio.Flow.cstruct_source
      (h2_cstruct_chunks ~chunk_size:13
         (h2_settings_frame
          ^ raw_headers encoder ~stream_id [ hpack_header ":status" "200" ]))
  in
  let rec read_until_response attempts =
    if attempts = 0 then Alcotest.fail "response headers were not delivered"
    else
      match Eta_http_eio.H2.Multiplexer.read_client_once ~flow:source reader with
      | Eta_http_eio.H2.Multiplexer.Read _ ->
          if Option.is_some !status then ()
          else read_until_response (attempts - 1)
      | Eof _ | Close -> Alcotest.fail "reader closed before response"
      | Security_error kind ->
          Alcotest.failf "unexpected security error: %s"
            (Eta_http.Error.kind_name kind)
  in
  read_until_response 16;
  Alcotest.(check bool)
    "final response marker does not enable global passthrough" false
    (Eta_http_eio.H2.Multiplexer.reader_is_passthrough reader);
  ignore (Eta_http_eio.H2.Multiplexer.release mux opened.stream);
  Alcotest.(check bool)
    "local release keeps filter active" false
    (Eta_http_eio.H2.Multiplexer.reader_is_passthrough reader)

let h2_body_closed_error =
  Eta_http.Error.make ~protocol:Eta_http.Error.H2 ~method_:"GET"
    ~uri:"https://api.example.test/"
    (Eta_http.Error.Connection_closed { during = Eta_http.Error.Http_response })

let test_h2_body_stream_async_bounded_recursion () =
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
  let client = Eta_http_eio.H2.Multiplexer.client_connection mux in
  let body_stream_ref = ref None in
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET "/large-buffered"
  in
  let opened =
    Eta_http_eio.H2.Multiplexer.request mux ~tag:1 request
      ~error_handler:(fun _stream _error -> ())
      ~response_handler:(fun stream _response body ->
        let stream_and_notify =
          Eta_http_eio.H2.Multiplexer.body_stream_async
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
  h2_pump_pair client server;
  let writer =
    match !held_writer with
    | Some w -> w
    | None -> Alcotest.fail "server did not install streaming writer"
  in
  for _ = 1 to num_chunks do
    H2.Body.Writer.write_string writer chunk_data
  done;
  H2.Body.Writer.close writer;
  h2_pump_pair client server;
  match !body_stream_ref with
  | None ->
      Alcotest.fail
        "body_stream_async was never created (response headers missing)"
  | Some (body_stream, notify) ->
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
      match result with
      | Eta.Exit.Ok () ->
          Alcotest.(check int) "full body delivered without loss" total_size
            !total_bytes
      | Eta.Exit.Error _ ->
          Alcotest.fail
            "body_stream_async failed to deliver pre-buffered response body +             (recursive schedule_read likely corrupted internal state)"
