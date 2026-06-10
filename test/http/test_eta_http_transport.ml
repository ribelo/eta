open Test_eta_http_support

let test_transport_resolve_stream_success () =
  let net = Eio_mock.Net.make "eta-http-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 443) in
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let target = Eta_http_eio.Transport.Connect.target_of_url url in
  Alcotest.(check string) "host" "example.test" target.host;
  Alcotest.(check int) "port" 443 target.port;
  with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http_eio.Transport.Connect.resolve_stream ~net ~method_:"GET" target
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "one address" 1 (List.length result)

let test_transport_resolve_stream_empty_is_typed () =
  let net = Eio_mock.Net.make "eta-http-net-empty" in
  Eio_mock.Net.on_getaddrinfo net [ `Return [] ];
  let url = Eta_http.Core.Url.of_string "https://missing.example.test/" in
  let target = Eta_http_eio.Transport.Connect.target_of_url url in
  with_test_clock @@ fun _sw _clock rt ->
  match
    Eta_http_eio.Transport.Connect.resolve_stream ~net ~method_:"GET" target
    |> Eta.Runtime.run rt
  with
  | Eta.Exit.Ok _ -> Alcotest.fail "empty DNS result unexpectedly succeeded"
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Dns_error { host; message }; _ }) ->
      Alcotest.(check string) "host" "missing.example.test" host;
      Alcotest.(check bool) "message" true
        (contains message "no stream addresses")
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected DNS failure shape: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let test_transport_resolve_stream_cancellation_propagates () =
  let net = Eio_mock.Net.make "eta-http-net-cancel-dns" in
  Eio_mock.Net.on_getaddrinfo net
    [ `Raise (Eio.Cancel.Cancelled (Failure "dns cancelled")) ];
  let url = Eta_http.Core.Url.of_string "https://cancel.example.test/" in
  let target = Eta_http_eio.Transport.Connect.target_of_url url in
  with_test_clock @@ fun _sw _clock rt ->
  match
    Eta_http_eio.Transport.Connect.resolve_stream ~net ~method_:"GET" target
    |> Eta.Runtime.run rt
  with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "DNS cancellation unexpectedly succeeded"
  | Eta.Exit.Error cause ->
      Alcotest.failf "DNS cancellation became a typed failure: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let test_transport_connect_tcp_success () =
  let net = Eio_mock.Net.make "eta-http-net-connect" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 443) in
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return (Eio_mock.Flow.make "eta-http-tcp") ];
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let target = Eta_http_eio.Transport.Connect.target_of_url url in
  with_test_clock @@ fun sw _clock rt ->
  Eta_http_eio.Transport.Connect.connect_tcp ~sw ~net ~method_:"GET" target
  |> Eta.Runtime.run rt
  |> Eta_test.Expect.expect_ok
  |> ignore

let test_transport_connect_tcp_failure_is_typed () =
  let net = Eio_mock.Net.make "eta-http-net-connect-fail" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 443) in
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Raise (Failure "connect boom") ];
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let target = Eta_http_eio.Transport.Connect.target_of_url url in
  with_test_clock @@ fun sw _clock rt ->
  match
    Eta_http_eio.Transport.Connect.connect_tcp ~sw ~net ~method_:"GET" target
    |> Eta.Runtime.run rt
  with
  | Eta.Exit.Ok _ -> Alcotest.fail "TCP connect unexpectedly succeeded"
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Connect_error { message }; _ }) ->
      Alcotest.(check bool) "message" true (contains message "connect boom")
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected connect failure shape: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let test_transport_connect_tcp_cancellation_propagates () =
  let net = Eio_mock.Net.make "eta-http-net-connect-cancel" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 443) in
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net
    [ `Raise (Eio.Cancel.Cancelled (Failure "connect cancelled")) ];
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let target = Eta_http_eio.Transport.Connect.target_of_url url in
  with_test_clock @@ fun sw _clock rt ->
  match
    Eta_http_eio.Transport.Connect.connect_tcp ~sw ~net ~method_:"GET" target
    |> Eta.Runtime.run rt
  with
  | exception Eio.Cancel.Cancelled _ -> ()
  | Eta.Exit.Ok _ -> Alcotest.fail "TCP cancellation unexpectedly succeeded"
  | Eta.Exit.Error cause ->
      Alcotest.failf "TCP cancellation became a typed failure: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let test_transport_connect_tcp_timeout_cancels_without_connect_error () =
  let net = Eio_mock.Net.make "eta-http-net-connect-timeout" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 443) in
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Run Eio.Fiber.await_cancel ];
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let uri = Eta_http.Core.Url.to_string url in
  let timeout_error =
    Eta_http.Error.make ~method_:"GET" ~uri
      (Connect_timeout { timeout_ms = Some 5 })
  in
  let target = Eta_http_eio.Transport.Connect.target_of_url url in
  with_test_clock @@ fun sw clock rt ->
  let timed =
    Eta_http_eio.Transport.Connect.connect_tcp ~sw ~net ~method_:"GET" target
    |> Eta.Effect.timeout_as (Eta.Duration.ms 5) ~on_timeout:timeout_error
  in
  let result = Eta_test.Async.fork_run sw rt timed in
  let rec wait_for_timeout attempts =
    if Eta_test.Test_clock.sleeper_count clock > 0 then ()
    else if attempts = 0 then Alcotest.fail "connect timeout was not registered"
    else (
      Eta_test.Async.yield ();
      wait_for_timeout (attempts - 1))
  in
  wait_for_timeout 50;
  Eta_test.Test_clock.adjust clock (Eta.Duration.ms 5);
  match Eta_test.Async.await result with
  | Eta.Exit.Error (Eta.Cause.Fail error) ->
      Alcotest.(check bool) "timeout error only" true (error = timeout_error)
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected only timeout, got %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause
  | Eta.Exit.Ok _ -> Alcotest.fail "connect timeout unexpectedly succeeded"

type counted_tls_flow = { closed : int ref }

module Counted_tls_flow = struct
  type t = counted_tls_flow

  let read_methods = []
  let single_read _ _ = raise End_of_file
  let single_write _ bufs = Cstruct.lenv bufs
  let copy t ~src = Eio.Flow.Pi.simple_copy ~single_write t ~src
  let shutdown _ _ = ()
  let close t = incr t.closed
end

let counted_tls_flow closed : Eta_http_eio.Transport.Connect.tcp_flow =
  Eio.Resource.T
    ( { closed },
      Eio.Resource.handler
        (Eio.Resource.H (Eio.Resource.Close, Counted_tls_flow.close)
        :: Eio.Resource.bindings
             (Eio.Flow.Pi.two_way (module Counted_tls_flow))) )

let test_transport_connect_tls_closes_flow_on_failure () =
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let target =
    { (Eta_http_eio.Transport.Connect.target_of_url url) with host = "bad host" }
  in
  let closed = ref 0 in
  let flow = counted_tls_flow closed in
  with_test_clock @@ fun _sw _clock rt ->
  match
    Eta_http_eio.Transport.Connect.connect_tls ~method_:"GET" target
      flow
    |> Eta.Runtime.run rt
  with
  | Eta.Exit.Ok _ -> Alcotest.fail "TLS connect unexpectedly succeeded"
  | Eta.Exit.Error
      (Eta.Cause.Fail
        { Eta_http.Error.kind = Tls_handshake_error _; _ }) ->
      Alcotest.(check int) "flow closed" 1 !closed
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected TLS failure shape: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let close_effect flow = Eta.Effect.sync (fun () -> Eio.Flow.close flow)

let test_transport_dispatch_unsupported_alpn_closes_flow () =
  let request = Eta_http.Request.make "GET" "https://example.test/path" in
  let closed = ref 0 in
  let flow = counted_tls_flow closed in
  with_test_clock @@ fun _sw _clock rt ->
  match
    Eta_http.Transport.Dispatch.dispatch_alpn
      ~close:(fun () -> close_effect flow)
      ~use_h1:(fun () -> Eta.Effect.pure `H1)
      ~use_h2:(fun () -> Eta.Effect.pure `H2)
      request (Some "spdy/3")
    |> Eta.Runtime.run rt
  with
  | Eta.Exit.Ok _ -> Alcotest.fail "unsupported ALPN unexpectedly succeeded"
  | Eta.Exit.Error
      (Eta.Cause.Fail
        {
          Eta_http.Error.kind =
            Tls_handshake_error
              { stage = Alpn_negotiation; message };
          _;
        }) ->
      Alcotest.(check bool) "message" true (contains message "spdy/3");
      Alcotest.(check int) "flow closed" 1 !closed
  | Eta.Exit.Error cause ->
      Alcotest.failf "unexpected ALPN failure shape: %a"
        (Eta.Cause.pp Eta_http.Error.pp)
        cause

let test_transport_dispatch_supported_alpn_keeps_flow_open () =
  let request = Eta_http.Request.make "GET" "https://example.test/path" in
  let closed = ref 0 in
  let flow = counted_tls_flow closed in
  with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http.Transport.Dispatch.dispatch_alpn
      ~close:(fun () -> close_effect flow)
      ~use_h1:(fun () -> Eta.Effect.pure `H1)
      ~use_h2:(fun () -> Eta.Effect.pure `H2)
      request (Some "h2")
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check bool) "h2 selected" true
    (match result with `H2 -> true | `H1 -> false);
  Alcotest.(check int) "flow still owned" 0 !closed
