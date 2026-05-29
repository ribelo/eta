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
  Eio_main.run @@ fun env ->
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
  Eio_main.run @@ fun env ->
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
  Eta_http.Client.For_test.request_h2_on_connection connection request
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
          (Eta_http.Client.For_test.request_h2_on_connection connection request
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
        Eta_http.Client.For_test.request_h2_on_connection connection request
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
        Eta_http.Client.For_test.request_h2_on_connection connection request
          (Eta_http.Request.url request)
        |> Eta.Effect.timeout_as (Eta.Duration.ms 5)
             ~on_timeout:(timeout_error uri)
      in
      (match Eta.Runtime.run rt effect with
      | Eta.Exit.Ok _ -> Alcotest.fail "expected upload cancellation"
      | Eta.Exit.Error _ -> ());
      Alcotest.(check int) "cancelled upload body released" 1 !released)

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
        Eta_http.Client.For_test.request_h2_on_connection connection request
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
      Alcotest.(check bool) "connection closed" true
        (Eta_http.H2.Connection.is_closed connection))

let test_h2_connection_cancelled_body_read_closes_connection () =
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
      Alcotest.(check bool) "connection closed" true
        (Eta_http.H2.Connection.is_closed connection))

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

let test_h2_client_classifies_informational_response () =
  Alcotest.(check bool) "100" true
    (Eta_http.Client.For_test.h2_informational_status 100);
  Alcotest.(check bool) "103" true
    (Eta_http.Client.For_test.h2_informational_status 103);
  Alcotest.(check bool) "101 excluded" false
    (Eta_http.Client.For_test.h2_informational_status 101);
  Alcotest.(check bool) "200 final" false
    (Eta_http.Client.For_test.h2_informational_status 200)
