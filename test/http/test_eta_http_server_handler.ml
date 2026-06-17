module Server = Eta_http.Server

let request path =
  {
    Server.Request.id = lazy "req-1";
    version = Eta_http.Core.Version.H2;
    scheme = "http";
    authority = Some "example.test";
    method_ = "GET";
    target = path;
    path;
    query = None;
    headers = Eta_http.Core.Header.empty;
    body = Server.Body.empty ();
    trailers = (fun () -> Eta.Effect.pure Eta_http.Core.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 1234 };
    tls = false;
    alpn_protocol = None;
    stream_id = Some 1;
    connection_id = "conn-1";
  }

let run_handler handler request =
  Test_eta_http_support.with_test_clock @@ fun _sw _clock rt ->
  Eta.Runtime.run rt (handler request)

let expect_ok = function
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Eta.Cause.pp Server.Error.pp) cause

let test_handler_of_sync () =
  let handler =
    Server.Handler.of_sync (fun _request ->
        Server.Response.text ~status:201 "created\n")
  in
  let response = expect_ok (run_handler handler (request "/created")) in
  Alcotest.(check int) "status" 201 (Server.Response.status response)

let test_handler_of_result_failure () =
  let error =
    Server.Error.make ~protocol:Server.Error.H2c ~method_:"GET" ~target:"/bad"
      (Server.Error.Bad_request { message = "bad" })
  in
  let handler = Server.Handler.of_result (fun _request -> Error error) in
  match run_handler handler (request "/bad") with
  | Eta.Exit.Error (Eta.Cause.Fail actual) ->
      Alcotest.(check string)
        "kind" (Server.Error.kind_name error.kind)
        (Server.Error.kind_name actual.kind)
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected typed failure, got %a"
        (Eta.Cause.pp Server.Error.pp)
        cause
  | Eta.Exit.Ok _ -> Alcotest.fail "expected typed failure"

let test_handler_of_effect () =
  let handler =
    Server.Handler.of_effect (fun _request ->
        Eta.Effect.pure (Server.Response.text "ok\n"))
  in
  let response = expect_ok (run_handler handler (request "/ok")) in
  Alcotest.(check int) "status" 200 (Server.Response.status response)
