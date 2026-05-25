open Test_eta_http_support

let test_alpn_state_collapses_pending_first_arrivals () =
  let alpn = Http.Transport.Alpn.create () in
  let leader =
    match Http.Transport.Alpn.begin_request alpn with
    | Leader pending -> pending
    | Wait _ | Ready _ -> Alcotest.fail "expected first request leader"
  in
  let waiter =
    match Http.Transport.Alpn.begin_request alpn with
    | Wait pending -> pending
    | Leader _ | Ready _ -> Alcotest.fail "expected second request waiter"
  in
  Alcotest.(check int) "same pending"
    (Http.Transport.Alpn.pending_id leader)
    (Http.Transport.Alpn.pending_id waiter);
  (match Http.Transport.Alpn.resolve alpn leader H2 with
  | Installed H2 -> ()
  | _ -> Alcotest.fail "expected h2 installation");
  (match Http.Transport.Alpn.begin_request alpn with
  | Ready H2 -> ()
  | Leader _ | Wait _ | Ready H1 -> Alcotest.fail "expected h2 ready route");
  let stats = Http.Transport.Alpn.stats alpn in
  Alcotest.(check int) "leaders" 1 stats.leaders;
  Alcotest.(check int) "waiters" 1 stats.waiters;
  Alcotest.(check int) "redundant cancelled" 1 stats.redundant_cancelled;
  Alcotest.(check int) "h2 resolved" 1 stats.h2_resolved

let test_alpn_state_ignores_stale_resolution_and_decodes_protocols () =
  let alpn = Http.Transport.Alpn.create () in
  let first =
    match Http.Transport.Alpn.begin_request alpn with
    | Leader pending -> pending
    | Wait _ | Ready _ -> Alcotest.fail "expected first leader"
  in
  Http.Transport.Alpn.cancel alpn first;
  let second =
    match Http.Transport.Alpn.begin_request alpn with
    | Leader pending -> pending
    | Wait _ | Ready _ -> Alcotest.fail "expected second leader"
  in
  (match Http.Transport.Alpn.resolve alpn first H2 with
  | Ignored -> ()
  | Installed _ | Already_ready _ -> Alcotest.fail "stale pending resolved");
  (match Http.Transport.Alpn.resolve alpn second H1 with
  | Installed H1 -> ()
  | _ -> Alcotest.fail "expected h1 installation");
  Alcotest.(check (result bool string)) "decode h2" (Ok true)
    (Result.map (( = ) Http.Transport.Alpn.H2)
       (Http.Transport.Alpn.protocol_of_alpn (Some "h2")));
  Alcotest.(check (result bool string)) "decode h1" (Ok true)
    (Result.map (( = ) Http.Transport.Alpn.H1)
       (Http.Transport.Alpn.protocol_of_alpn (Some "http/1.1")));
  Alcotest.(check (result bool string)) "missing ALPN falls back h1" (Ok true)
    (Result.map (( = ) Http.Transport.Alpn.H1)
       (Http.Transport.Alpn.protocol_of_alpn None));
  Alcotest.(check (result bool string)) "unknown ALPN rejected" (Error "spdy/3")
    (Result.map (( = ) Http.Transport.Alpn.H1)
       (Http.Transport.Alpn.protocol_of_alpn (Some "spdy/3")))

let test_dispatch_decides_alpn_route () =
  (match Http.Transport.Dispatch.decide_alpn (Some "h2") with
  | Ok Use_h2 -> ()
  | Ok Use_h1 -> Alcotest.fail "h2 ALPN routed to h1"
  | Error protocol -> Alcotest.failf "h2 ALPN rejected: %s" protocol);
  (match Http.Transport.Dispatch.decide_alpn (Some "http/1.1") with
  | Ok Use_h1 -> ()
  | Ok Use_h2 -> Alcotest.fail "http/1.1 ALPN routed to h2"
  | Error protocol -> Alcotest.failf "http/1.1 ALPN rejected: %s" protocol);
  (match Http.Transport.Dispatch.decide_alpn None with
  | Ok Use_h1 -> ()
  | Ok Use_h2 -> Alcotest.fail "missing ALPN routed to h2"
  | Error protocol -> Alcotest.failf "missing ALPN rejected: %s" protocol);
  Alcotest.(check (result string string)) "unknown ALPN" (Error "spdy/3")
    (Result.map
       (fun decision ->
         Http.Transport.Dispatch.protocol_to_string
           (Http.Transport.Dispatch.decision_protocol decision))
       (Http.Transport.Dispatch.decide_alpn (Some "spdy/3")))


