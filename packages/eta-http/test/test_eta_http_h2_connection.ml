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

let with_h2_server handler client_action =
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

let blocking_body () =
  let first = ref true in
  let never, _resolver = Eio.Promise.create () in
  Eta_http.Body.Stream.of_reader (fun () ->
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

let test_h2_connection_returns_early_response () =
  with_h2_server
    (fun reqd ->
      H2.Reqd.respond_with_string reqd (H2.Response.create (`Code 413)) "")
    (fun _clock rt connection ->
      let uri = "https://api.example.test/early" in
      let request =
        Eta_http.Request.make "POST" uri
          ~body:(Eta_http.Request.Stream (blocking_body ()))
      in
      let effect =
        Eta_http.Client.For_test.request_h2_on_connection connection request
          (Eta_http.Request.url request)
        |> Eta.Effect.timeout_as (Eta.Duration.seconds 1)
             ~on_timeout:(timeout_error uri)
      in
      let response = Eta.Runtime.run rt effect |> Eta_test.Expect.expect_ok in
      Alcotest.(check int) "early status" 413 response.status)

let test_h2_client_classifies_informational_response () =
  Alcotest.(check bool) "100" true
    (Eta_http.Client.For_test.h2_informational_status 100);
  Alcotest.(check bool) "103" true
    (Eta_http.Client.For_test.h2_informational_status 103);
  Alcotest.(check bool) "101 excluded" false
    (Eta_http.Client.For_test.h2_informational_status 101);
  Alcotest.(check bool) "200 final" false
    (Eta_http.Client.For_test.h2_informational_status 200)
