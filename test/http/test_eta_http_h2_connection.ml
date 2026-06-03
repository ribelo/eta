open Test_eta_http_support

let tcp_port = function
  | `Tcp (_, port) -> port
  | `Unix _ -> Alcotest.fail "expected TCP listener"

let cstruct_of_iovec ({ H2.IOVec.buffer; off; len } : Bigstringaf.t H2.IOVec.t) =
  Cstruct.of_bigarray ~off ~len buffer

let iovecs_len =
  List.fold_left (fun total ({ H2.IOVec.len; _ } : _ H2.IOVec.t) -> total + len) 0

let write_iovecs flow iovecs =
  let written = iovecs_len iovecs in
  Eio.Flow.write flow (List.map cstruct_of_iovec iovecs);
  written

let read_into_connection flow read conn =
  let chunk = Cstruct.create 0x4000 in
  let len = Eio.Flow.single_read flow chunk in
  let data = Cstruct.to_string (Cstruct.sub chunk 0 len) in
  let buffer = Bigstringaf.of_string ~off:0 ~len data in
  ignore (read conn buffer ~off:0 ~len : int)

let rec run_server_writer flow server =
  match H2.Server_connection.next_write_operation server with
  | `Write iovecs ->
      let written = write_iovecs flow iovecs in
      H2.Server_connection.report_write_result server (`Ok written);
      run_server_writer flow server
  | `Yield ->
      let promise, resolver = Eio.Promise.create () in
      H2.Server_connection.yield_writer server (fun () ->
          ignore (Eio.Promise.try_resolve resolver ()));
      Eio.Promise.await promise;
      run_server_writer flow server
  | `Close _ ->
      H2.Server_connection.report_write_result server `Closed;
      (try Eio.Flow.shutdown flow `Send with _ -> ())

let rec run_server_reader flow server =
  match H2.Server_connection.next_read_operation server with
  | `Read ->
      read_into_connection flow H2.Server_connection.read server;
      run_server_reader flow server
  | `Close -> ()

let run_h2_server flow handler =
  Eio.Switch.run @@ fun sw ->
  let server =
    H2.Server_connection.create
      ~error_handler:(fun ?request:_ _ respond ->
        let body = respond H2.Headers.empty in
        H2.Body.Writer.close body)
      handler
  in
  Eio.Fiber.fork ~sw (fun () -> run_server_writer flow server);
  Fun.protect
    ~finally:(fun () ->
      H2.Server_connection.shutdown server;
      try Eio.Flow.shutdown flow `All with _ -> ())
    (fun () -> try run_server_reader flow server with End_of_file -> ())

let with_h2_server ?max_concurrent handler client_action =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run @@ fun conn_sw ->
      let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
      run_h2_server flow handler);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http.H2.Connection.create ~sw ~flow:(flow :> Eta_http.H2.Connection.flow)
      ?max_concurrent ()
  in
  let rt = Eta.Runtime.create ~sw ~clock () in
  Fun.protect
    ~finally:(fun () -> Eta_http.H2.Connection.shutdown connection)
    (fun () -> client_action clock rt connection)

let with_raw_h2_server server client_action =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run @@ fun conn_sw ->
      let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
      server flow);
  let flow =
    Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
  in
  let connection =
    Eta_http.H2.Connection.create ~sw ~flow:(flow :> Eta_http.H2.Connection.flow)
      ()
  in
  let rt = Eta.Runtime.create ~sw ~clock () in
  Fun.protect
    ~finally:(fun () -> Eta_http.H2.Connection.shutdown connection)
    (fun () -> client_action clock rt connection)

let request_effect ?body connection target =
  let uri = "https://api.example.test" ^ target in
  let request = Eta_http.Request.make ?body "GET" uri in
  Eta_http.Client.request_h2_on_connection connection request
    (Eta_http.Request.url request)
  |> Eta.Effect.bind (fun response ->
         Eta_http.Body.Stream.read_all response.body
         |> Eta.Effect.map (fun body ->
                (response.Eta_http.Response.status, Bytes.to_string body)))

let open_h2_request connection tag target =
  let request =
    H2.Request.create ~scheme:"https"
      ~headers:(H2.Headers.of_list [ ":authority", "api.example.test" ])
      `GET target
  in
  match
    Eta_http.H2.Connection.request connection ~tag request
      ~error_handler:(fun _ _ -> ())
      ~response_handler:(fun _ _ _ -> ())
  with
  | Ok opened -> opened
  | Error (Eta_http.H2.Multiplexer.Admission_rejected { limit }) ->
      Alcotest.failf "request %d unexpectedly rejected at limit %d" tag limit
  | Error Eta_http.H2.Multiplexer.Connection_closed ->
      Alcotest.failf "request %d saw closed connection" tag
  | Error (Eta_http.H2.Multiplexer.Request_failed message) ->
      Alcotest.failf "request %d failed: %s" tag message

let test_h2_connection_admission_error_reports_configured_limit () =
  with_h2_server ~max_concurrent:64
    (fun _reqd -> ())
    (fun _clock rt connection ->
      let held =
        List.init 64 (fun index ->
            open_h2_request connection index
              (Printf.sprintf "/held/%d" index))
      in
      ignore (held : Eta_http.H2.Multiplexer.opened_request list);
      let request =
        Eta_http.Request.make "GET" "https://api.example.test/overflow"
      in
      match
        Eta.Runtime.run rt
          (Eta_http.Client.request_h2_on_connection connection request
             (Eta_http.Request.url request))
      with
      | Eta.Exit.Error
          (Eta.Cause.Fail
            {
              Eta_http.Error.kind = Stream_admission_rejected { limit };
              _;
            }) ->
          Alcotest.(check int) "configured limit" 64 limit
      | Eta.Exit.Ok _ -> Alcotest.fail "admission-limited request succeeded"
      | Eta.Exit.Error cause ->
          Alcotest.failf "unexpected failure: %a"
            (Eta.Cause.pp Eta_http.Error.pp)
            cause)

let test_h2_connection_concurrent_streams () =
  with_h2_server
    (fun reqd ->
      let target = (H2.Reqd.request reqd).target in
      H2.Reqd.respond_with_string reqd (H2.Response.create `OK)
        ("ok:" ^ target))
    (fun _clock rt connection ->
      let responses =
        List.init 10 (fun i ->
            request_effect connection (Printf.sprintf "/concurrent/%d" i))
        |> Eta.Effect.all |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
      in
      List.iteri
        (fun i (status, body) ->
          Alcotest.(check int) "status" 200 status;
          Alcotest.(check string) "body"
            (Printf.sprintf "ok:/concurrent/%d" i)
            body)
        responses;
      let stats = Eta_http.H2.Connection.stats connection in
      Alcotest.(check int) "active streams" 0 stats.active;
      Alcotest.(check int) "opened streams" 10 stats.opened)

let blocking_body ?(release = fun () -> Eta.Effect.unit) () =
  let first = ref true in
  let never, _resolver = Eio.Promise.create () in
  Eta_http.Body.Stream.of_reader ~release (fun () ->
      if !first then (
        first := false;
        Eta.Effect.pure
          (Eta_http.Body.Stream.Chunk (Bytes.of_string (String.make 1024 'x'))))
      else
        Eta.Effect.sync (fun () -> Eio.Promise.await never)
        |> Eta.Effect.map (fun () -> Eta_http.Body.Stream.End))

let timeout_error uri =
  Eta_http.Error.make ~protocol:H2 ~method_:"POST" ~uri
    (Connection_protocol_violation
       { kind = "test_timeout"; message = "h2 request timed out" })

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "%s did not become true" label
    else (
      Eta_test.Async.yield ();
      loop (attempts - 1))
  in
  loop 50

let pp_http_error_detail fmt (error : Eta_http.Error.t) =
  match error.kind with
  | Connection_protocol_violation { kind; message } ->
      Format.fprintf fmt "%a detail=%s:%s" Eta_http.Error.pp error kind message
  | _ -> Eta_http.Error.pp fmt error

let test_h2_connection_returns_early_response () =
  with_h2_server
    (fun reqd ->
      H2.Reqd.respond_with_string reqd (H2.Response.create (`Code 413)) "")
    (fun _clock rt connection ->
      let uri = "https://api.example.test/early" in
      let released = ref 0 in
      let request =
        Eta_http.Request.make "POST" uri
          ~body:
            (Eta_http.Request.Stream
               (blocking_body
                  ~release:(fun () ->
                    incr released;
                    Eta.Effect.unit)
                  ()))
      in
      let effect =
        Eta_http.Client.request_h2_on_connection connection request
          (Eta_http.Request.url request)
        |> Eta.Effect.timeout_as (Eta.Duration.seconds 1)
             ~on_timeout:(timeout_error uri)
      in
      let response = Eta.Runtime.run rt effect |> Eta_test.Expect.expect_ok in
      Alcotest.(check int) "early status" 413 response.status;
      Alcotest.(check int) "upload body released" 1 !released)

let test_h2_connection_cancelled_upload_releases_body () =
  with_h2_server
    (fun _reqd -> ())
    (fun _clock rt connection ->
      let uri = "https://api.example.test/cancel-upload" in
      let released = ref 0 in
      let request =
        Eta_http.Request.make "POST" uri
          ~body:
            (Eta_http.Request.Stream
               (blocking_body
                  ~release:(fun () ->
                    incr released;
                    Eta.Effect.unit)
                  ()))
      in
      let effect =
        Eta_http.Client.request_h2_on_connection connection request
          (Eta_http.Request.url request)
        |> Eta.Effect.timeout_as (Eta.Duration.ms 5)
             ~on_timeout:(timeout_error uri)
      in
      (match Eta.Runtime.run rt effect with
      | Eta.Exit.Ok _ -> Alcotest.fail "expected upload cancellation"
      | Eta.Exit.Error _ -> ());
      Alcotest.(check int) "cancelled upload body released" 1 !released)

let test_h2_connection_stream_upload_observes_flow_control () =
  let chunk_count = 8 in
  let flow = Eio_mock.Flow.make "eta-http-h2-flow-control-upload-flow" in
  let write_started, wake_write_started = Eio.Promise.create () in
  let release_write, wake_release_write = Eio.Promise.create () in
  let read_never = Eta_test.Async.unresolved () in
  Eio_mock.Flow.on_copy_bytes flow
    [
      `Run
        (fun () ->
          ignore (Eio.Promise.try_resolve wake_write_started ());
          Eio.Promise.await release_write);
    ];
  Eio_mock.Flow.on_read flow [ `Await read_never ];
  with_test_clock @@ fun sw clock rt ->
  let connection =
    Eta_http.H2.Connection.create ~sw
      ~flow:(flow :> Eta_http.H2.Connection.flow)
      ()
  in
  let reads = ref 0 in
  let released = ref 0 in
  let body =
    Eta_http.Body.Stream.of_reader
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      (fun () ->
        if !reads >= chunk_count then Eta.Effect.pure Eta_http.Body.Stream.End
        else (
          incr reads;
          Eta.Effect.pure
            (Eta_http.Body.Stream.Chunk (Bytes.make 1024 'x'))))
  in
  let uri = "https://api.example.test/flow-control-upload" in
  let request =
    Eta_http.Request.make "POST" uri ~body:(Eta_http.Request.Stream body)
  in
  let result =
    Eta_test.Async.fork_run sw rt
      (Eta_http.Client.request_h2_on_connection connection request
         (Eta_http.Request.url request)
      |> Eta.Effect.timeout_as (Eta.Duration.ms 1)
           ~on_timeout:(timeout_error uri))
  in
  wait_until "request write blocked" (fun () ->
      Eio.Promise.is_resolved write_started);
  for _ = 1 to 10 do
    Eta_test.Async.yield ()
  done;
  Alcotest.(check bool)
    "stream source was not drained without transport progress" true
    (!reads < chunk_count);
  Eta_test.Test_clock.adjust clock (Eta.Duration.ms 1);
  (match Eta_test.Async.await result with
  | Eta.Exit.Ok _ -> Alcotest.fail "closed upload unexpectedly succeeded"
  | Eta.Exit.Error _ -> ());
  Eio.Promise.resolve wake_release_write 4096;
  Eta_http.H2.Connection.shutdown connection;
  Alcotest.(check int) "stream released" 1 !released

let test_h2_connection_cancelled_fixed_request_releases_stream () =
  with_h2_server
    (fun _reqd -> ())
    (fun _clock rt connection ->
      let uri = "https://api.example.test/cancel-fixed" in
      let request =
        Eta_http.Request.make "POST" uri
          ~body:(Eta_http.Request.Fixed [ Bytes.of_string "{}" ])
      in
      let effect =
        Eta_http.Client.request_h2_on_connection connection request
          (Eta_http.Request.url request)
        |> Eta.Effect.timeout_as (Eta.Duration.ms 5)
             ~on_timeout:(timeout_error uri)
      in
      (match Eta.Runtime.run rt effect with
      | Eta.Exit.Error
          (Eta.Cause.Fail
            { Eta_http.Error.kind = Connection_protocol_violation _; _ }) ->
          ()
      | Eta.Exit.Error cause ->
          Alcotest.failf "expected typed timeout, got %a"
            (Eta.Cause.pp pp_http_error_detail)
            cause
      | Eta.Exit.Ok _ -> Alcotest.fail "expected fixed request cancellation");
      let stats = Eta_http.H2.Connection.stats connection in
      Alcotest.(check int) "active streams" 0 stats.active;
      Alcotest.(check int) "live streams" 0 stats.live;
      Alcotest.(check int) "local resets" 1 stats.local_resets;
      Alcotest.(check bool) "connection remains open" false
        (Eta_http.H2.Connection.is_closed connection))

let test_h2_connection_cancelled_body_read_preserves_connection () =
  with_h2_server
    (fun reqd ->
      let body = H2.Reqd.respond_with_streaming reqd (H2.Response.create `OK) in
      H2.Body.Writer.write_string body "partial")
    (fun _clock rt connection ->
      let uri = "https://api.example.test/body-stall" in
      let effect =
        request_effect connection "/body-stall"
        |> Eta.Effect.timeout_as (Eta.Duration.ms 5)
             ~on_timeout:(timeout_error uri)
      in
      (match Eta.Runtime.run rt effect with
      | Eta.Exit.Error
          (Eta.Cause.Fail
            { Eta_http.Error.kind = Connection_protocol_violation _; _ }) ->
          ()
      | Eta.Exit.Error cause ->
          Alcotest.failf "expected body-read timeout, got %a"
            (Eta.Cause.pp pp_http_error_detail)
            cause
      | Eta.Exit.Ok _ -> Alcotest.fail "expected body-read timeout");
      let stats = Eta_http.H2.Connection.stats connection in
      Alcotest.(check int) "active streams" 0 stats.active;
      Alcotest.(check int) "live streams" 0 stats.live;
      Alcotest.(check bool) "connection remains open" false
        (Eta_http.H2.Connection.is_closed connection))

let test_h2_connection_completed_error_response_does_not_hold_switch () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run @@ fun conn_sw ->
      let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
      run_h2_server flow (fun reqd ->
          H2.Reqd.respond_with_string reqd (H2.Response.create (`Code 401))
            "{\"error\":{\"message\":\"bad key\",\"code\":401}}"));
  let completed, completed_resolver = Eio.Promise.create () in
  let returned, returned_resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run (fun client_sw ->
          let flow =
            Eio.Net.connect ~sw:client_sw net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
          in
          let connection =
            Eta_http.H2.Connection.create ~sw:client_sw
              ~flow:(flow :> Eta_http.H2.Connection.flow)
              ()
          in
          let rt = Eta.Runtime.create ~sw:client_sw ~clock () in
          let status, body =
            request_effect connection "/unauthorized"
            |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
          in
          Alcotest.(check int) "status" 401 status;
          Alcotest.(check string)
            "body"
            "{\"error\":{\"message\":\"bad key\",\"code\":401}}"
            body;
          Eio.Promise.resolve completed_resolver ());
      Eio.Promise.resolve returned_resolver ());
  Eio.Promise.await completed;
  match
    Eio.Time.with_timeout clock 0.05 (fun () ->
        Eio.Promise.await returned;
        Ok ())
  with
  | Ok () -> ()
  | Error `Timeout ->
      Alcotest.fail "completed H2 response kept the client switch open"

let hpack_header name value = { Hpack.name; value; sensitive = false }

let hpack_block encoder headers =
  let faraday = Faraday.create 0x1000 in
  List.iter (Hpack.Encoder.encode_header encoder faraday) headers;
  Faraday.serialize_to_string faraday

let raw_headers encoder ?(end_stream = false) ~stream_id headers =
  let block = hpack_block encoder headers in
  let flags = 0x4 lor (if end_stream then 0x1 else 0) in
  Eta_http.H2.Frame.header ~length:(String.length block) ~frame_type:Headers
    ~flags ~stream_id
  ^ block

let raw_data ?(end_stream = false) ~stream_id data =
  let flags = if end_stream then 0x1 else 0 in
  Eta_http.H2.Frame.header ~length:(String.length data) ~frame_type:Data ~flags
    ~stream_id
  ^ data

let test_h2_informational_filter_passes_push_promise_continuation () =
  let filter = Eta_http.H2.Informational_filter.create () in
  let push_fragment = Eta_http.H2.Frame.uint32 2 ^ "push-a" in
  let push_promise =
    Eta_http.H2.Frame.header ~length:(String.length push_fragment)
      ~frame_type:Push_promise ~flags:0 ~stream_id:1
    ^ push_fragment
  in
  let continuation_payload = "push-b" in
  let continuation =
    Eta_http.H2.Frame.header ~length:(String.length continuation_payload)
      ~frame_type:Continuation ~flags:0x4 ~stream_id:1
    ^ continuation_payload
  in
  let input = push_promise ^ continuation in
  (match Eta_http.H2.Informational_filter.feed filter input ~off:0
           ~len:(String.length input) with
  | Ok () -> ()
  | Error kind ->
      Alcotest.failf "unexpected filter error: %s"
        (Eta_http.Error.kind_name kind));
  Alcotest.(check string) "push promise passthrough" input
    (Eta_http.H2.Informational_filter.take filter)

let raw_informational_response_server flow =
  let encoder = Hpack.Encoder.create 4096 in
  let early =
    raw_headers encoder ~stream_id:1
      [ hpack_header ":status" "103"; hpack_header "x-reused" "yes" ]
  in
  let final =
    raw_headers encoder ~stream_id:1
      [
        hpack_header ":status" "200";
        hpack_header "content-length" "5";
        hpack_header "x-reused" "yes";
      ]
  in
  let body = raw_data ~end_stream:true ~stream_id:1 "final" in
  let response =
    String.concat "" [ Eta_http.H2.Frame.settings; early; final; body ]
  in
  Eio.Flow.write flow [ Cstruct.of_string response ];
  let chunk = Cstruct.create 0x4000 in
  let rec drain () =
    match Eio.Flow.single_read flow chunk with
    | _ -> drain ()
    | exception End_of_file -> ()
  in
  drain ()

(* Server that sends partial body then GOAWAY, used by the GOAWAY-during-body test *)
let raw_goaway_mid_body_server flow =
  let encoder = Hpack.Encoder.create 4096 in
  (* Send server preface (SETTINGS) *)
  let settings_frame = Eta_http.H2.Frame.settings in
  (* Response headers for stream 1 (no content-length, streaming) *)
  let response_headers =
    raw_headers encoder ~stream_id:1
      [ hpack_header ":status" "200" ]
  in
  (* First data chunk (NOT end_stream) *)
  let data1 = raw_data ~stream_id:1 "chunk1" in
  (* Send settings + response headers + first data *)
  Eio.Flow.write flow
    [ Cstruct.of_string (String.concat "" [ settings_frame; response_headers; data1 ]) ];
  (* Read client preface and request *)
  let chunk = Cstruct.create 0x4000 in
  (try ignore (Eio.Flow.single_read flow chunk) with _ -> ());
  (* Small delay to ensure client processes first chunk *)
  Eio.Fiber.yield ();
  (* Send GOAWAY with last_stream_id=1 (allows stream 1 to complete) *)
  let goaway = Eta_http.H2.Frame.goaway_no_error ~last_stream_id:1 in
  (* Then send more data and close stream *)
  let data2 = raw_data ~end_stream:true ~stream_id:1 "chunk2" in
  (try
     Eio.Flow.write flow
       [ Cstruct.of_string (String.concat "" [ goaway; data2 ]) ]
   with _ -> ());
  (* Drain remaining client frames *)
  let rec drain () =
    match Eio.Flow.single_read flow chunk with
    | _ -> drain ()
    | exception End_of_file -> ()
  in
  drain ()

let test_h2_connection_continues_after_informational_headers () =
  with_raw_h2_server raw_informational_response_server
    (fun _clock rt connection ->
      let effect =
        request_effect connection "/early-hints"
        |> Eta.Effect.timeout_as (Eta.Duration.seconds 1)
             ~on_timeout:(timeout_error "https://api.example.test/early-hints")
      in
      match Eta.Runtime.run rt effect with
      | Eta.Exit.Ok (status, body) ->
          Alcotest.(check int) "final status" 200 status;
          Alcotest.(check string) "final body" "final" body
      | Eta.Exit.Error cause ->
          Alcotest.failf "expected final response, got %a"
            (Eta.Cause.pp pp_http_error_detail)
            cause)

(* Test GOAWAY mid-body: server sends response headers + partial body,
   then GOAWAY with last_stream_id covering our stream, then finishes
   the body. The client should read the complete body despite GOAWAY. *)
let test_h2_connection_goaway_mid_body_completes_existing_stream () =
  with_raw_h2_server raw_goaway_mid_body_server
    (fun _clock rt connection ->
      let effect =
        request_effect connection "/goaway-mid"
        |> Eta.Effect.timeout_as (Eta.Duration.seconds 2)
             ~on_timeout:(timeout_error "https://api.example.test/goaway-mid")
      in
      match Eta.Runtime.run rt effect with
      | Eta.Exit.Ok (status, body) ->
          Alcotest.(check int) "status" 200 status;
          Alcotest.(check string) "complete body" "chunk1chunk2" body
      | Eta.Exit.Error cause ->
          Alcotest.failf
            "GOAWAY mid-body killed existing stream: %a"
            (Eta.Cause.pp pp_http_error_detail)
            cause)

let test_h2_connection_timeout_preserves_connection () =
  with_h2_server
    (fun reqd ->
      match (H2.Reqd.request reqd).target with
      | "/fast" ->
          H2.Reqd.respond_with_string reqd (H2.Response.create `OK) "fast"
      | _ -> () (* /slow: never respond *))
    (fun _clock rt connection ->
      (* Request that never gets a response -> times out *)
      let uri = "https://api.example.test/slow" in
      let timeout_result =
        request_effect connection "/slow"
        |> Eta.Effect.timeout_as (Eta.Duration.ms 10)
             ~on_timeout:(timeout_error uri)
        |> Eta.Runtime.run rt
      in
      (match timeout_result with
      | Eta.Exit.Error _ -> ()
      | Eta.Exit.Ok _ -> Alcotest.fail "expected timeout");
      Alcotest.(check bool) "connection remains open after timeout" false
        (Eta_http.H2.Connection.is_closed connection);
      let retry_result =
        request_effect connection "/fast" |> Eta.Runtime.run rt
      in
      match retry_result with
      | Eta.Exit.Ok (status, body) ->
          Alcotest.(check int) "retry status" 200 status;
          Alcotest.(check string) "retry body" "fast" body
      | Eta.Exit.Error cause ->
          Alcotest.failf "connection unusable after one stream timeout: %a"
            (Eta.Cause.pp pp_http_error_detail)
            cause)

(* GREEN TEST: security_error_handler should not fire on clean switch close.
   Currently passes because writer daemon runs first, closes the flow,
   and the reader exits via End_of_file (not the exn path). The bug is
   latent: if Eio scheduling changes and reader catches Cancelled first,
   security_error_handler would fire spuriously. *)
let test_h2_connection_switch_close_does_not_fire_security_error () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  let security_errors = ref [] in
  (* Server responds normally then keeps connection open *)
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run @@ fun conn_sw ->
      let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
      run_h2_server flow (fun reqd ->
          H2.Reqd.respond_with_string reqd (H2.Response.create `OK) "ok"));
  (* Client: connect, complete one request, let switch close (daemons cancelled) *)
  Eio.Switch.run (fun client_sw ->
      let flow =
        Eio.Net.connect ~sw:client_sw net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      let connection =
        Eta_http.H2.Connection.create ~sw:client_sw
          ~flow:(flow :> Eta_http.H2.Connection.flow)
          ~security_error_handler:(fun kind ->
            security_errors := kind :: !security_errors)
          ()
      in
      let rt = Eta.Runtime.create ~sw:client_sw ~clock () in
      let status, body =
        request_effect connection "/test"
        |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
      in
      Alcotest.(check int) "status" 200 status;
      Alcotest.(check string) "body" "ok" body
      (* client_sw closes here, daemon reader cancelled, on_error fires *));
  Alcotest.(check int)
    "security_error_handler must not fire on clean switch close" 0
    (List.length !security_errors)

(* RED TEST: daemon cancellation should report Connection_closed, not
   Connection_protocol_violation. When the switch closes, the daemon
   catches Eio.Cancel.Cancelled and calls fail_connection with a protocol
   violation error kind. Any registered failure handler observes the
   wrong classification, which also breaks retryability (protocol
   violations are Not_retryable, connection closed is retryable). *)
let test_h2_connection_failure_kind_on_switch_close_is_not_protocol_violation () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  (* Server: respond to one request then keep connection open *)
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run @@ fun conn_sw ->
      let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
      run_h2_server flow (fun reqd ->
          H2.Reqd.respond_with_string reqd (H2.Response.create `OK) "ok"));
  let failure_kind = ref None in
  (* Client: connect, register failure handler, make request, let switch close *)
  Eio.Switch.run (fun client_sw ->
      let flow =
        Eio.Net.connect ~sw:client_sw net
          (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
      in
      let connection =
        Eta_http.H2.Connection.create ~sw:client_sw
          ~flow:(flow :> Eta_http.H2.Connection.flow)
          ()
      in
      (* Register a persistent failure handler that outlives the request *)
      let _unregister =
        Eta_http.H2.Connection.register_failure_handler connection (fun kind ->
            if Option.is_none !failure_kind then failure_kind := Some kind)
      in
      let rt = Eta.Runtime.create ~sw:client_sw ~clock () in
      let status, body =
        request_effect connection "/test"
        |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
      in
      Alcotest.(check int) "status" 200 status;
      Alcotest.(check string) "body" "ok" body
      (* client_sw closes here, daemons cancelled, fail_connection fires *));
  match !failure_kind with
  | None ->
      Alcotest.fail "no failure notification on switch close"
  | Some (Eta_http.Error.Connection_closed _) -> ()
  | Some (Eta_http.Error.Connection_protocol_violation { message; _ })
    when contains message "Cancel" ->
      Alcotest.fail
        "daemon cancellation classified as Connection_protocol_violation; \
         expected Connection_closed"
  | Some kind ->
      Alcotest.failf "unexpected failure kind: %s"
        (Eta_http.Error.kind_name kind)

(* RED TEST: body stream error on daemon cancellation should be Connection_closed,
   not Connection_protocol_violation with "Cancelled".
   Bug: Eio.Cancel.Cancelled caught as generic exn in run_owner_loop sets
   failure to Connection_protocol_violation, which is Not_retryable and
   misleading. *)
(* RED TEST: failure handler exception skips remaining handlers.
   set_failure uses List.iter without catching individual handler
   exceptions. If one handler raises, the rest never fire. This breaks
   cleanup guarantees for components that rely on failure notifications. *)
let test_h2_connection_failure_handler_exception_skips_others () =
  run_eio @@ fun _env ->
  Eio.Switch.run @@ fun sw ->
  let (flow_r, _flow_w) = Eio_unix.Net.socketpair_stream ~sw () in
  let handler1_called = ref false in
  let handler2_called = ref false in
  let connection =
    Eta_http.H2.Connection.create ~sw
      ~flow:(flow_r :> Eta_http.H2.Connection.flow)
      ()
  in
  (* Register the well-behaved handler FIRST, then the raising handler.
     Failure handlers are prepended to the list, so the raising handler
     (registered second) fires first and stops iteration. *)
  let _unregister2 =
    Eta_http.H2.Connection.register_failure_handler connection (fun _kind ->
        handler2_called := true)
  in
  let _unregister1 =
    Eta_http.H2.Connection.register_failure_handler connection (fun _kind ->
        handler1_called := true;
        raise (Failure "handler1 boom"))
  in
  (try Eta_http.H2.Connection.shutdown connection
   with Failure _ -> ());
  Alcotest.(check bool) "handler1 called" true !handler1_called;
  Alcotest.(check bool) "handler2 still called despite handler1 raising" true
    !handler2_called

let test_h2_connection_body_error_on_switch_close_is_connection_closed () =
  run_eio @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:1 net
      (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
  in
  let port = tcp_port (Eio.Net.listening_addr socket) in
  (* Server: send response headers + partial body, never close stream *)
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run @@ fun conn_sw ->
      let flow, _addr = Eio.Net.accept ~sw:conn_sw socket in
      run_h2_server flow (fun reqd ->
          let body =
            H2.Reqd.respond_with_streaming reqd (H2.Response.create `OK)
          in
          H2.Body.Writer.write_string body "partial"));
  (* Client: connect, read first body chunk, return body stream, close switch *)
  let body_promise, body_resolver = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      Eio.Switch.run (fun client_sw ->
          let flow =
            Eio.Net.connect ~sw:client_sw net
              (`Tcp (Eio.Net.Ipaddr.V4.loopback, port))
          in
          let connection =
            Eta_http.H2.Connection.create ~sw:client_sw
              ~flow:(flow :> Eta_http.H2.Connection.flow)
              ()
          in
          let rt = Eta.Runtime.create ~sw:client_sw ~clock () in
          let uri = "https://api.example.test/stream" in
          let request = Eta_http.Request.make "GET" uri in
          let response =
            Eta_http.Client.request_h2_on_connection connection request
              (Eta_http.Request.url request)
            |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
          in
          (* Read first chunk to confirm body is live *)
          let chunk =
            Eta_http.Body.Stream.read response.body
            |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
          in
          Alcotest.(check (option string)) "first chunk" (Some "partial")
            (Option.map Bytes.to_string chunk);
          Eio.Promise.resolve body_resolver response.body)
      (* client_sw closed here: daemons cancelled, failure set *));
  (* Read body from outer scope after daemon cancellation *)
  let body = Eio.Promise.await body_promise in
  let rt = Eta.Runtime.create ~sw ~clock () in
  match Eta_http.Body.Stream.read body |> Eta.Runtime.run rt with
  | Eta.Exit.Ok None -> () (* acceptable: stream already released *)
  | Eta.Exit.Ok (Some _) ->
      Alcotest.fail "unexpected body data after connection switch closed"
  | Eta.Exit.Error
      (Eta.Cause.Fail { Eta_http.Error.kind = Connection_closed _; _ }) ->
      () (* correct error kind for lifecycle closure *)
  | Eta.Exit.Error
      (Eta.Cause.Fail
        {
          Eta_http.Error.kind =
            Connection_protocol_violation { message; _ };
          _;
        })
    when contains message "Cancel" ->
      Alcotest.fail
        "body stream reported Cancelled as protocol violation; expected \
         Connection_closed"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected error kind: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause
