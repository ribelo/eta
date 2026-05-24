open Test_eta_http_support

let test_transport_resolve_stream_success () =
  let net = Eio_mock.Net.make "eta-http-net" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 443) in
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let target = Eta_http.Transport.Connect.target_of_url url in
  Alcotest.(check string) "host" "example.test" target.host;
  Alcotest.(check int) "port" 443 target.port;
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http.Transport.Connect.resolve_stream ~net ~method_:"GET" target
    |> Eta.Runtime.run rt
    |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check int) "one address" 1 (List.length result)

let test_transport_resolve_stream_empty_is_typed () =
  let net = Eio_mock.Net.make "eta-http-net-empty" in
  Eio_mock.Net.on_getaddrinfo net [ `Return [] ];
  let url = Eta_http.Core.Url.of_string "https://missing.example.test/" in
  let target = Eta_http.Transport.Connect.target_of_url url in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  match
    Eta_http.Transport.Connect.resolve_stream ~net ~method_:"GET" target
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

let test_transport_connect_tcp_success () =
  let net = Eio_mock.Net.make "eta-http-net-connect" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 443) in
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Return (Eio_mock.Flow.make "eta-http-tcp") ];
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let target = Eta_http.Transport.Connect.target_of_url url in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  Eta_http.Transport.Connect.connect_tcp ~sw ~net ~method_:"GET" target
  |> Eta.Runtime.run rt
  |> Eta_test.Expect.expect_ok
  |> ignore

let test_transport_connect_tcp_failure_is_typed () =
  let net = Eio_mock.Net.make "eta-http-net-connect-fail" in
  let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 443) in
  Eio_mock.Net.on_getaddrinfo net [ `Return [ addr ] ];
  Eio_mock.Net.on_connect net [ `Raise (Failure "connect boom") ];
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let target = Eta_http.Transport.Connect.target_of_url url in
  Eta_test.with_test_clock @@ fun sw _clock rt ->
  match
    Eta_http.Transport.Connect.connect_tcp ~sw ~net ~method_:"GET" target
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

let counted_tls_flow closed : Eta_http.Transport.Connect.tcp_flow =
  Eio.Resource.T
    ( { closed },
      Eio.Resource.handler
        (Eio.Resource.H (Eio.Resource.Close, Counted_tls_flow.close)
        :: Eio.Resource.bindings
             (Eio.Flow.Pi.two_way (module Counted_tls_flow))) )

let test_transport_connect_tls_closes_flow_on_failure () =
  let url = Eta_http.Core.Url.of_string "https://example.test/path" in
  let target =
    { (Eta_http.Transport.Connect.target_of_url url) with host = "bad host" }
  in
  let authenticator =
    match Ca_certs.authenticator () with
    | Ok authenticator -> authenticator
    | Error (`Msg message) -> Alcotest.fail message
  in
  let closed = ref 0 in
  let flow = counted_tls_flow closed in
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  match
    Eta_http.Transport.Connect.connect_tls ~authenticator ~method_:"GET" target
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
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  match
    Eta_http.Client.For_test.dispatch_alpn
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
  Eta_test.with_test_clock @@ fun _sw _clock rt ->
  let result =
    Eta_http.Client.For_test.dispatch_alpn
      ~close:(fun () -> close_effect flow)
      ~use_h1:(fun () -> Eta.Effect.pure `H1)
      ~use_h2:(fun () -> Eta.Effect.pure `H2)
      request (Some "h2")
    |> Eta.Runtime.run rt |> Eta_test.Expect.expect_ok
  in
  Alcotest.(check bool) "h2 selected" true
    (match result with `H2 -> true | `H1 -> false);
  Alcotest.(check int) "flow still owned" 0 !closed

