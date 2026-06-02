open Test_eta_http_support

let read_file path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let rec find_sub_from haystack ~needle index =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if index + needle_len > haystack_len then None
  else if String.sub haystack index needle_len = needle then Some index
  else find_sub_from haystack ~needle (index + 1)

let find_sub haystack ~needle = find_sub_from haystack ~needle 0

let require_sub haystack ~needle =
  match find_sub haystack ~needle with
  | Some index -> index
  | None -> Alcotest.failf "missing source marker: %s" needle

let find_http_client_source () =
  let candidates =
    [
      "lib/http/client/client.ml";
      "../lib/http/client/client.ml";
      "../../lib/http/client/client.ml";
      "../../../lib/http/client/client.ml";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "could not locate client.ml from %s" (Sys.getcwd ())

let test_auto_client_uses_alpn_dispatch_state () =
  let source = read_file (find_http_client_source ()) in
  ignore (require_sub source ~needle:"type alpn_gate = {" : int);
  ignore
    (require_sub source
       ~needle:"alpn_gates : (string, alpn_gate) Hashtbl.t;" : int);
  ignore (require_sub source ~needle:"let begin_alpn state key =" : int);
  ignore (require_sub source ~needle:"Alpn.begin_request gate.alpn" : int);
  ignore (require_sub source ~needle:"Eio.Promise.await pending.promise" : int);
  ignore (require_sub source ~needle:"Alpn.resolve gate.alpn pending protocol" : int);
  ignore (require_sub source ~needle:"Alpn.cancel gate.alpn pending" : int);
  ignore (require_sub source ~needle:"begin_alpn state key" : int)

let test_alpn_state_collapses_pending_first_arrivals () =
  let alpn = Eta_http.Transport.Alpn.create () in
  let leader =
    match Eta_http.Transport.Alpn.begin_request alpn with
    | Leader pending -> pending
    | Wait _ | Ready _ -> Alcotest.fail "expected first request leader"
  in
  let waiter =
    match Eta_http.Transport.Alpn.begin_request alpn with
    | Wait pending -> pending
    | Leader _ | Ready _ -> Alcotest.fail "expected second request waiter"
  in
  Alcotest.(check int) "same pending"
    (Eta_http.Transport.Alpn.pending_id leader)
    (Eta_http.Transport.Alpn.pending_id waiter);
  (match Eta_http.Transport.Alpn.resolve alpn leader H2 with
  | Installed H2 -> ()
  | _ -> Alcotest.fail "expected h2 installation");
  (match Eta_http.Transport.Alpn.begin_request alpn with
  | Ready H2 -> ()
  | Leader _ | Wait _ | Ready H1 -> Alcotest.fail "expected h2 ready route");
  let stats = Eta_http.Transport.Alpn.stats alpn in
  Alcotest.(check int) "leaders" 1 stats.leaders;
  Alcotest.(check int) "waiters" 1 stats.waiters;
  Alcotest.(check int) "redundant cancelled" 1 stats.redundant_cancelled;
  Alcotest.(check int) "h2 resolved" 1 stats.h2_resolved

let test_alpn_state_ignores_stale_resolution_and_decodes_protocols () =
  let alpn = Eta_http.Transport.Alpn.create () in
  let first =
    match Eta_http.Transport.Alpn.begin_request alpn with
    | Leader pending -> pending
    | Wait _ | Ready _ -> Alcotest.fail "expected first leader"
  in
  Eta_http.Transport.Alpn.cancel alpn first;
  let second =
    match Eta_http.Transport.Alpn.begin_request alpn with
    | Leader pending -> pending
    | Wait _ | Ready _ -> Alcotest.fail "expected second leader"
  in
  (match Eta_http.Transport.Alpn.resolve alpn first H2 with
  | Ignored -> ()
  | Installed _ | Already_ready _ -> Alcotest.fail "stale pending resolved");
  (match Eta_http.Transport.Alpn.resolve alpn second H1 with
  | Installed H1 -> ()
  | _ -> Alcotest.fail "expected h1 installation");
  Alcotest.(check (result bool string)) "decode h2" (Ok true)
    (Result.map (( = ) Eta_http.Transport.Alpn.H2)
       (Eta_http.Transport.Alpn.protocol_of_alpn (Some "h2")));
  Alcotest.(check (result bool string)) "decode h1" (Ok true)
    (Result.map (( = ) Eta_http.Transport.Alpn.H1)
       (Eta_http.Transport.Alpn.protocol_of_alpn (Some "http/1.1")));
  Alcotest.(check (result bool string)) "missing ALPN falls back h1" (Ok true)
    (Result.map (( = ) Eta_http.Transport.Alpn.H1)
       (Eta_http.Transport.Alpn.protocol_of_alpn None));
  Alcotest.(check (result bool string)) "unknown ALPN rejected" (Error "spdy/3")
    (Result.map (( = ) Eta_http.Transport.Alpn.H1)
       (Eta_http.Transport.Alpn.protocol_of_alpn (Some "spdy/3")))

let test_dispatch_decides_alpn_route () =
  (match Eta_http.Transport.Dispatch.decide_alpn (Some "h2") with
  | Ok Use_h2 -> ()
  | Ok Use_h1 -> Alcotest.fail "h2 ALPN routed to h1"
  | Error protocol -> Alcotest.failf "h2 ALPN rejected: %s" protocol);
  (match Eta_http.Transport.Dispatch.decide_alpn (Some "http/1.1") with
  | Ok Use_h1 -> ()
  | Ok Use_h2 -> Alcotest.fail "http/1.1 ALPN routed to h2"
  | Error protocol -> Alcotest.failf "http/1.1 ALPN rejected: %s" protocol);
  (match Eta_http.Transport.Dispatch.decide_alpn None with
  | Ok Use_h1 -> ()
  | Ok Use_h2 -> Alcotest.fail "missing ALPN routed to h2"
  | Error protocol -> Alcotest.failf "missing ALPN rejected: %s" protocol);
  Alcotest.(check (result string string)) "unknown ALPN" (Error "spdy/3")
    (Result.map
       (fun decision ->
         Eta_http.Transport.Dispatch.protocol_to_string
           (Eta_http.Transport.Dispatch.decision_protocol decision))
       (Eta_http.Transport.Dispatch.decide_alpn (Some "spdy/3")))

