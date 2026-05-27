open Test_eta_http_support

let test_h1_client_request_on_flow_fixed_response () =
  let flow = Eio_mock.Flow.make "eta-http-h1-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello" ];
  let url = Eta_http.Core.Url.of_string "http://example.test/models" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  Alcotest.(check (option string))
    "content-length" (Some "5")
    (Eta_http.Core.Header.get "content-length" response.headers);
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello" (Bytes.to_string body)

let test_h1_client_reads_split_response () =
  let flow = Eio_mock.Flow.make "eta-http-h1-split-flow" in
  Eio_mock.Flow.on_read flow
    [
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n";
      `Return "\r\nhe";
      `Return "llo";
    ];
  let url = Eta_http.Core.Url.of_string "http://example.test/split" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello" (Bytes.to_string body)

let test_h1_client_decodes_chunked_response () =
  let flow = Eio_mock.Flow.make "eta-http-h1-chunked-flow" in
  Eio_mock.Flow.on_read flow
    [
      `Return
        "HTTP/1.1 200 OK\r\n\
         Transfer-Encoding: chunked\r\n\
         \r\n\
         4\r\n\
         Wiki\r\n\
         5\r\n\
         pedia\r\n\
         0\r\n\
         X-Trailer: ok\r\n\
         \r\n";
    ];
  let url = Eta_http.Core.Url.of_string "http://example.test/chunked" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let trailers =
    response.trailers () |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "Wikipedia" (Bytes.to_string body);
  Alcotest.(check (option string))
    "trailer" (Some "ok")
    (Eta_http.Core.Header.get "x-trailer" trailers)

let test_h1_client_caps_close_delimited_body () =
  let flow = Eio_mock.Flow.make "eta-http-h1-close-delimited-cap-flow" in
  let body_chunks =
    List.init 17 (fun _ -> `Return (String.make (64 * 1024) 'x'))
  in
  Eio_mock.Flow.on_read flow
    (`Return "HTTP/1.1 200 OK\r\n\r\n" :: body_chunks);
  let url = Eta_http.Core.Url.of_string "http://example.test/close-delimited" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Eta.Runtime.run rt (Eta_http.Body.Stream.read_all response.body)
  |> expect_body_too_large "close-delimited" ~limit:body_size_cap

let test_h1_client_streaming_request_body_releases () =
  let flow = Eio_mock.Flow.make "eta-http-h1-stream-request-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" ];
  let released = ref 0 in
  let body =
    Eta_http.Body.Stream.of_bytes
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      [ Bytes.of_string "abc"; Bytes.of_string "def" ]
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/upload" in
  let request : Eta_http.H1.Client.request =
    { method_ = "POST"; url; headers = []; body = Eta_http.H1.Client.Eta_stream body }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let response_body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "response" "ok" (Bytes.to_string response_body);
  Alcotest.(check int) "request body released" 1 !released

let h1_blocking_body ~released () =
  let first = ref true in
  let never, _resolver = Eio.Promise.create () in
  Eta_http.Body.Stream.of_reader
    ~release:(fun () ->
      incr released;
      Eta.Effect.unit)
    (fun () ->
      if !first then (
        first := false;
        Eta.Effect.pure
          (Eta_http.Body.Stream.Chunk (Bytes.of_string (String.make 1024 'x'))))
      else
        Eta.Effect.sync (fun () -> Eio.Promise.await never)
        |> Eta.Effect.map (fun () -> Eta_http.Body.Stream.End))

let h1_timeout_error uri =
  Eta_http.Error.make ~protocol:H1 ~method_:"POST" ~uri
    (Connection_closed { during = Cancellation })

let test_h1_client_cancelled_streaming_request_body_releases () =
  let flow = Eio_mock.Flow.make "eta-http-h1-stream-cancel-flow" in
  let released = ref 0 in
  let uri = "http://example.test/cancel-upload" in
  let url = Eta_http.Core.Url.of_string uri in
  let request : Eta_http.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [];
      body = Eta_http.H1.Client.Eta_stream (h1_blocking_body ~released ());
    }
  in
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let timed =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Effect.timeout_as (Eta.Duration.ms 5)
         ~on_timeout:(h1_timeout_error uri)
  in
  let result = Eta_test.Async.fork_run sw rt timed in
  let rec wait_for_timeout attempts =
    if Eta_test.Test_clock.sleeper_count clock > 0 then ()
    else if attempts = 0 then Alcotest.fail "request timeout was not registered"
    else (
      Eta_test.Async.yield ();
      wait_for_timeout (attempts - 1))
  in
  wait_for_timeout 50;
  Eta_test.Test_clock.adjust clock (Eta.Duration.ms 5);
  let result = Eta_test.Async.await result in
  Eta_test.Expect.expect_typed_failure result (function
    | { Eta_http.Error.kind = Connection_closed { during = Cancellation }; _ } ->
        true
    | _ -> false);
  Alcotest.(check int) "cancelled body released" 1 !released

let test_h1_client_streaming_request_body_releases_on_write_failure () =
  let flow = Eio_mock.Flow.make "eta-http-h1-stream-write-fail-flow" in
  Eio_mock.Flow.on_copy_bytes flow
    [ `Raise (Unix.Unix_error (Unix.EPIPE, "write", "")) ];
  let released = ref 0 in
  let url = Eta_http.Core.Url.of_string "http://example.test/write-fail" in
  let request : Eta_http.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers = [];
      body = Eta_http.H1.Client.Eta_stream (h1_blocking_body ~released ());
    }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http.H1.Client.request_on_flow ~flow request |> Eta.Runtime.run rt
  in
  Eta_test.Expect.expect_typed_failure result (function
    | { Eta_http.Error.kind = Connection_closed { during = Http_request }; _ } ->
        true
    | _ -> false);
  Alcotest.(check int) "failed write body released" 1 !released

let test_h1_client_custom_release_on_write_failure () =
  let flow = Eio_mock.Flow.make "eta-http-h1-write-release-flow" in
  Eio_mock.Flow.on_copy_bytes flow
    [ `Raise (Unix.Unix_error (Unix.EPIPE, "write", "")) ];
  let released = ref 0 in
  let url = Eta_http.Core.Url.of_string "http://example.test/write-fail" in
  let request : Eta_http.H1.Client.request =
    { method_ = "POST"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http.H1.Client.request_on_flow
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      ~flow request
    |> Eta.Runtime.run rt
  in
  Eta_test.Expect.expect_typed_failure result (function
    | { Eta_http.Error.kind = Connection_closed { during = Http_request }; _ } ->
        true
    | _ -> false);
  Alcotest.(check int) "released" 1 !released

let test_h1_client_custom_release_on_response_header_failure () =
  let flow = Eio_mock.Flow.make "eta-http-h1-read-release-flow" in
  let released = ref 0 in
  let url = Eta_http.Core.Url.of_string "http://example.test/read-fail" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http.H1.Client.request_on_flow
      ~release:(fun () ->
        incr released;
        Eta.Effect.unit)
      ~flow request
    |> Eta.Runtime.run rt
  in
  Eta_test.Expect.expect_typed_failure result (function
    | { Eta_http.Error.kind = Connection_closed { during = Http_response }; _ } ->
        true
    | _ -> false);
  Alcotest.(check int) "released" 1 !released

let test_h1_client_head_ignores_chunked_body_headers () =
  let flow = Eio_mock.Flow.make "eta-http-h1-head-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ];
  let url = Eta_http.Core.Url.of_string "http://example.test/head" in
  let request : Eta_http.H1.Client.request =
    { method_ = "HEAD"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "empty body" 0 (Bytes.length body)

let test_h1_client_skips_100_continue () =
  let flow = Eio_mock.Flow.make "eta-http-h1-continue-flow" in
  Eio_mock.Flow.on_read flow
    [
      `Return
        "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    ];
  let url = Eta_http.Core.Url.of_string "http://example.test/continue" in
  let headers =
    Eta_http.Core.Header.unsafe_of_list [ "Expect", "100-continue" ]
  in
  let request : Eta_http.H1.Client.request =
    {
      method_ = "POST";
      url;
      headers;
      body = Eta_http.H1.Client.Fixed [ Bytes.of_string "abc" ];
    }
  in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let response =
    Eta_http.H1.Client.request_on_flow ~flow request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "ok" (Bytes.to_string body)

let test_h1_pool_reuses_healthy_idle_connection () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-h1-pool-flow" in
  Eio_mock.Flow.on_read flow
    [
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none";
      `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo";
    ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let health_checks = ref 0 in
  let health_check _flow =
    incr health_checks;
    Eta.Effect.unit
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/pool" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~health_check ~sw ~net
      url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http.H1.Client.request_with_pool pool request
      |> Eta.Runtime.run rt
      |> Eta_test.Expect.expect_ok
    in
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
    |> Bytes.to_string
  in
  Alcotest.(check string) "first body" "one" (read_once ());
  Alcotest.(check string) "second body" "two" (read_once ());
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "one TCP open" 1 stats.Eta.Pool.opened;
  Alcotest.(check int) "idle" 1 stats.idle;
  Alcotest.(check int) "health check on reuse" 1 !health_checks

let test_h1_pool_rejects_unhealthy_idle_connection () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-unhealthy-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let first_flow = Eio_mock.Flow.make "eta-http-h1-pool-first-flow" in
  let second_flow = Eio_mock.Flow.make "eta-http-h1-pool-second-flow" in
  Eio_mock.Flow.on_read first_flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none" ];
  Eio_mock.Flow.on_read second_flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ]; `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return first_flow; `Return second_flow ];
  let health_checks = ref 0 in
  let health_check _flow =
    incr health_checks;
    Eta.Effect.fail
      (Eta_http.Error.make ~protocol:H1 ~method_:"*" ~uri:"http://example.test"
         (Connection_closed { during = Pool }))
  in
  let url = Eta_http.Core.Url.of_string "http://example.test/pool" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~health_check ~sw ~net
      url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let read_once () =
    let response =
      Eta_http.H1.Client.request_with_pool pool request
      |> Eta.Runtime.run rt
      |> Eta_test.Expect.expect_ok
    in
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
    |> Bytes.to_string
  in
  Alcotest.(check string) "first body" "one" (read_once ());
  Alcotest.(check string) "second body" "two" (read_once ());
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "two TCP opens" 2 stats.Eta.Pool.opened;
  Alcotest.(check int) "one rejected" 1 stats.health_rejected;
  Alcotest.(check int) "one closed" 1 stats.closed;
  Alcotest.(check int) "health check called" 1 !health_checks

let test_h1_pool_holds_checkout_until_body_eof () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-release-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-h1-pool-release-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let url = Eta_http.Core.Url.of_string "http://example.test/release" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let response =
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let open_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "active while body open" 1 open_stats.active;
  Alcotest.(check int) "not idle while body open" 0 open_stats.idle;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "hello" (Bytes.to_string body);
  let closed_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "released after eof" 0 closed_stats.active;
  Alcotest.(check int) "idle after eof" 1 closed_stats.idle

let test_h1_pool_discard_releases_checkout () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-discard-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-h1-pool-discard-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndrop" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let url = Eta_http.Core.Url.of_string "http://example.test/discard" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let response =
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let open_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "active while body open" 1 open_stats.active;
  Alcotest.(check int) "not idle while body open" 0 open_stats.idle;
  Eta_http.Body.Stream.discard response.body
  |> Eta.Runtime.run rt
  |> Eta_test.Expect.expect_ok;
  let closed_stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "released after discard" 0 closed_stats.active;
  Alcotest.(check int) "idle after discard" 1 closed_stats.idle

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "%s did not become true" label
    else (
      Eta_test.Async.yield ();
      loop (attempts - 1))
  in
  loop 50

let test_h1_pool_request_cancellation_releases_checkout () =
  let net = Eio_mock.Net.make "eta-http-h1-pool-cancel-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-h1-pool-cancel-flow" in
  let never = Eta_test.Async.unresolved () in
  Eio_mock.Flow.on_read flow [ `Await never ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  let url = Eta_http.Core.Url.of_string "http://example.test/cancel" in
  let request : Eta_http.H1.Client.request =
    { method_ = "GET"; url; headers = []; body = Eta_http.H1.Client.Empty }
  in
  Eta_test.with_test_clock @@ fun sw clock rt ->
  let pool =
    Eta_http.H1.Client.make_pool ~max_size:1 ~sw ~net url
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  let timed =
    let timeout_error =
      Eta_http.Error.make ~protocol:H1 ~method_:"GET"
        ~uri:"http://example.test/cancel"
        (Response_header_timeout { timeout_ms = Some 1 })
    in
    Eta_http.H1.Client.request_with_pool pool request
    |> Eta.Effect.timeout_as (Eta.Duration.ms 1) ~on_timeout:timeout_error
  in
  let result = Eta_test.Async.fork_run sw rt timed in
  wait_until "request active" (fun () ->
      (Eta_http.H1.Client.pool_stats pool).active = 1);
  Eta_test.Test_clock.adjust clock (Eta.Duration.ms 1);
  (match Eta_test.Async.await result with
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Response_header_timeout { timeout_ms = Some 1 }; _ }) ->
      ()
  | Eta.Exit.Ok _ -> Alcotest.fail "cancelled request unexpectedly succeeded"
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected cancellation result: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause);
  wait_until "request checkout released" (fun () ->
      (Eta_http.H1.Client.pool_stats pool).active = 0);
  let stats = Eta_http.H1.Client.pool_stats pool in
  Alcotest.(check int) "active released" 0 stats.active

let test_client_make_h1_request_path () =
  let net = Eio_mock.Net.make "eta-http-client-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 80) in
  let flow = Eio_mock.Flow.make "eta-http-client-flow" in
  Eio_mock.Flow.on_read flow
    [ `Return "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" ];
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return flow ];
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  let client = Eta_http.Client.make_h1 ~sw ~net () in
  let request = Eta_http.Request.make "GET" "http://example.test/models" in
  let response =
    Eta_http.request client request |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "status" 200 response.status;
  let body =
    Eta_http.Body.Stream.read_all response.body
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check string) "body" "ok" (Bytes.to_string body)
