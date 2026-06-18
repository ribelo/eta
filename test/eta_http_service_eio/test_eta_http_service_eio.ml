module S = Eta_http.Server
module Serve = Eta_http_service_eio.Serve

let free_tcp_port () =
  let fd = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close fd)
    (fun () ->
      Unix.setsockopt fd Unix.SO_REUSEADDR true;
      Unix.bind fd (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname fd with
      | Unix.ADDR_INET (_, port) -> port
      | Unix.ADDR_UNIX _ -> Alcotest.fail "expected TCP port")

let request ?(method_ = "GET") ?(target = "/") () =
  let path, query = S.Request.split_target target in
  {
    S.Request.id = lazy "serve-test";
    version = Eta_http.Core.Version.H1_1;
    scheme = "http";
    authority = Some "example.test";
    method_;
    target;
    path;
    query;
    headers = Eta_http.Core.Header.empty;
    body = S.Body.empty ();
    trailers = (fun () -> Eta.Effect.pure Eta_http.Core.Header.empty);
    peer = { address = Some "127.0.0.1"; port = Some 8080 };
    tls = false;
    alpn_protocol = None;
    stream_id = None;
    connection_id = "serve-test-conn";
  }

let response_body_string response =
  match S.Response.body response with
  | S.Response.Body.Empty -> ""
  | Fixed chunks -> Bytes.to_string (Bytes.concat Bytes.empty chunks)
  | Stream _ -> Alcotest.fail "expected fixed response body"

let run_server_fiber ~sw f =
  let done_, resolve_done = Eio.Promise.create () in
  Eio.Fiber.fork ~sw (fun () ->
      let outcome =
        try Ok (f ()) with
        | exn -> Error exn
      in
      ignore (Eio.Promise.try_resolve resolve_done outcome));
  done_

let connect_retry ~sw ~net ~clock port =
  let rec loop attempts =
    try Eio.Net.connect ~sw net (`Tcp (Eio.Net.Ipaddr.V4.loopback, port)) with
    | exn when attempts > 0 ->
        Eio.Time.sleep clock 0.01;
        loop (attempts - 1)
    | exn -> raise exn
  in
  loop 200

let read_all_response flow =
  let buffer = Buffer.create 128 in
  let scratch = Cstruct.create 1024 in
  let rec loop () =
    match Eio.Flow.single_read flow scratch with
    | 0 -> Buffer.contents buffer
    | len ->
        Buffer.add_string buffer (Cstruct.to_string (Cstruct.sub scratch 0 len));
        loop ()
    | exception End_of_file -> Buffer.contents buffer
  in
  loop ()

let await_server_done clock done_ =
  match Eio.Time.with_timeout_exn clock 2.0 (fun () -> Eio.Promise.await done_) with
  | Ok () -> ()
  | Error exn -> raise exn

let test_with_readiness_default_and_user_owned () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let user_handler _request =
    Eta.Effect.pure (S.Response.text ~status:209 "user-ready\n")
  in
  let generated = Serve.with_readiness ~ready:(fun () -> false) user_handler in
  let response =
    match Eta_eio.Runtime.run rt (generated (request ~target:"/ready" ())) with
    | Eta.Exit.Ok response -> response
    | Eta.Exit.Error cause ->
        Alcotest.failf "unexpected failure: %a" (Eta.Cause.pp S.Error.pp) cause
  in
  Alcotest.(check int) "generated status" 503 (S.Response.status response);
  Alcotest.(check string) "generated body" "draining\n"
    (response_body_string response);
  let user_owned =
    Serve.with_readiness ~ready_path:None ~ready:(fun () -> false) user_handler
  in
  let response =
    match Eta_eio.Runtime.run rt (user_owned (request ~target:"/ready" ())) with
    | Eta.Exit.Ok response -> response
    | Eta.Exit.Error cause ->
        Alcotest.failf "unexpected failure: %a" (Eta.Cause.pp S.Error.pp) cause
  in
  Alcotest.(check int) "user status" 209 (S.Response.status response);
  Alcotest.(check string) "user body" "user-ready\n"
    (response_body_string response)

let test_h1_serve_ready_and_external_stop () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let port = free_tcp_port () in
  let stop, resolve_stop = Eio.Promise.create () in
  let handler _request = Eta.Effect.pure (S.Response.text "app\n") in
  let done_ =
    run_server_fiber ~sw (fun () ->
        Serve.h1 ~sw ~net ~clock ~stop ~port handler)
  in
  let flow = connect_retry ~sw ~net ~clock port in
  Fun.protect
    ~finally:(fun () -> try Eio.Flow.shutdown flow `All with _ -> ())
    (fun () ->
      Eio.Flow.copy_string
        "GET /ready HTTP/1.1\r\nHost: example.test\r\nConnection: close\r\n\r\n"
        flow;
      let response =
        Eio.Time.with_timeout_exn clock 1.0 (fun () -> read_all_response flow)
      in
      Alcotest.(check bool) "ready status" true
        (String.starts_with ~prefix:"HTTP/1.1 200 OK" response);
      Alcotest.(check bool) "ready body" true
        (String.ends_with ~suffix:"ready\n" response));
  ignore (Eio.Promise.try_resolve resolve_stop ());
  await_server_done clock done_

let run_h2_request rt connection uri =
  let request = Eta_http.Request.make "GET" uri in
  let effect =
    Eta_http_eio.Client.request_h2_on_connection connection request
      (Eta_http.Request.url request)
    |> Eta.Effect.bind (fun response ->
           Eta_http.Body.Stream.read_all response.body
           |> Eta.Effect.map (fun body ->
                  (response.Eta_http.Response.status, Bytes.to_string body)))
  in
  match Eta_eio.Runtime.run rt effect with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected h2 client failure: %a"
        (Eta.Cause.pp Eta_http.Error.pp) cause

let test_h2c_serve_ready_and_external_stop () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let port = free_tcp_port () in
  let stop, resolve_stop = Eio.Promise.create () in
  let handler _request = Eta.Effect.pure (S.Response.text "app\n") in
  let done_ =
    run_server_fiber ~sw (fun () ->
        Serve.h2c ~sw ~net ~clock ~stop ~port handler)
  in
  let flow = connect_retry ~sw ~net ~clock port in
  let connection =
    Eta_http_eio.H2.Connection.create ~sw ~now_ms:(fun () -> 0L)
      ~flow:(flow :> Eta_http_eio.H2.Connection.flow)
      ()
  in
  let rt = Eta_eio.Runtime.create ~sw ~clock () in
  Fun.protect
    ~finally:(fun () ->
      Eta_http_eio.H2.Connection.shutdown connection;
      ignore (Eio.Promise.try_resolve resolve_stop ()))
    (fun () ->
      let status, body =
        run_h2_request rt connection
          (Printf.sprintf "http://127.0.0.1:%d/ready" port)
      in
      Alcotest.(check int) "h2 ready status" 200 status;
      Alcotest.(check string) "h2 ready body" "ready\n" body);
  await_server_done clock done_

let () =
  Alcotest.run "eta-http-service-eio"
    [
      ( "readiness",
        [
          Alcotest.test_case "handler readiness" `Quick
            test_with_readiness_default_and_user_owned;
        ] );
      ( "serve",
        [
          Alcotest.test_case "h1 ready and stop" `Quick
            test_h1_serve_ready_and_external_stop;
          Alcotest.test_case "h2c ready and stop" `Quick
            test_h2c_serve_ready_and_external_stop;
        ] );
    ]
