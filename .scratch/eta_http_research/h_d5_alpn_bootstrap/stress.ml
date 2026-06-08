open Eta

let host = "example.test"
let port = 443

let fail msg = failwith msg

let check label cond =
  if not cond then fail ("FAIL " ^ label) else Printf.printf "PASS %s\n%!" label

let render_error fmt = function
  | `Admission_limited -> Format.pp_print_string fmt "Admission_limited"
  | `Closed -> Format.pp_print_string fmt "Closed"
  | `Connection_cancelled -> Format.pp_print_string fmt "Connection_cancelled"
  | `Pool_shutdown -> Format.pp_print_string fmt "Pool_shutdown"
  | `Pool_shutdown_timeout -> Format.pp_print_string fmt "Pool_shutdown_timeout"
  | `Socket_closed -> Format.pp_print_string fmt "Socket_closed"
  | `Stream_reset -> Format.pp_print_string fmt "Stream_reset"
  | `Writer_full -> Format.pp_print_string fmt "Writer_full"

let run effect =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let result = Runtime.run rt effect in
  Runtime.drain rt;
  result

let run_ok label effect =
  match run effect with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "%s failed: %a\n%!" label (Cause.pp render_error) cause;
      fail ("unexpected Eta failure in " ^ label)

let h2_id = function `H2 id -> Some id | `H1 _ -> None
let is_h1 = function `H1 _ -> true | `H2 _ -> false

let test_single_request () =
  let server = Fixture_server.create Pending_connection.H2 in
  let response, stats =
    run_ok "single request"
      (Pool_dispatch.with_dispatcher server (fun dispatch ->
           Pool_dispatch.request dispatch ~host ~port ~tag:1
           |> Effect.bind (fun response ->
                  Pool_dispatch.stats dispatch
                  |> Effect.map (fun stats -> (response, stats)))))
  in
  let server_stats = Fixture_server.stats server in
  check "single request opens one h2 connection cleanly"
    (h2_id response = Some 1 && stats.Pool_dispatch.h2_cells = 1
   && stats.h2_requests = 1 && server_stats.pending_live = 0
   && server_stats.h2_opened = 1 && server_stats.h2_closed = 1)

let test_concurrent_h2_collapse () =
  let server = Fixture_server.create ~delay:(Duration.ms 20) Pending_connection.H2 in
  let (a, b), stats =
    run_ok "h2 collapse"
      (Pool_dispatch.with_dispatcher server (fun dispatch ->
           Effect.par
             (Pool_dispatch.request dispatch ~host ~port ~tag:1)
             (Pool_dispatch.request dispatch ~host ~port ~tag:2)
           |> Effect.bind (fun responses ->
                  Pool_dispatch.stats dispatch
                  |> Effect.map (fun stats -> (responses, stats)))))
  in
  check "two concurrent h2 requests share one multiplexer"
    (h2_id a = Some 1 && h2_id b = Some 1
   && stats.Pool_dispatch.h2_cells = 1 && stats.h2_requests = 2)

let test_pending_collapse_cancels_redundant () =
  let server = Fixture_server.create ~delay:(Duration.ms 30) Pending_connection.H2 in
  let stats =
    run_ok "pending collapse"
      (Pool_dispatch.with_dispatcher server (fun dispatch ->
           Effect.par
             (Pool_dispatch.request dispatch ~host ~port ~tag:1)
             (Pool_dispatch.request dispatch ~host ~port ~tag:2)
           |> Effect.bind (fun _ -> Pool_dispatch.stats dispatch)))
  in
  let server_stats = Fixture_server.stats server in
  check "pending first-arrivals collapse and free redundant connection"
    (stats.Pool_dispatch.h2_cells = 1 && stats.redundant_cancelled >= 1
   && server_stats.pending_opened >= 2 && server_stats.pending_cancelled >= 1
   && server_stats.pending_live = 0 && server_stats.h2_opened = 1
   && server_stats.h2_closed = 1)

let test_third_waiter_during_alpn () =
  let server = Fixture_server.create ~delay:(Duration.ms 40) Pending_connection.H2 in
  let ((a, b), c), stats =
    run_ok "third waiter"
      (Pool_dispatch.with_dispatcher server (fun dispatch ->
           Effect.par
             (Effect.par
                (Pool_dispatch.request dispatch ~host ~port ~tag:1)
                (Pool_dispatch.request dispatch ~host ~port ~tag:2))
             (Effect.delay (Duration.ms 5)
                (Pool_dispatch.request dispatch ~host ~port ~tag:3))
           |> Effect.bind (fun responses ->
                  Pool_dispatch.stats dispatch
                  |> Effect.map (fun stats -> (responses, stats)))))
  in
  check "third request waits for in-flight ALPN and dispatches h2"
    (h2_id a = Some 1 && h2_id b = Some 1 && h2_id c = Some 1
   && stats.Pool_dispatch.h2_cells = 1 && stats.h2_requests = 3)

let test_unexpected_h1_pool_dispatch () =
  let server = Fixture_server.create Pending_connection.H1 in
  let response, stats =
    run_ok "unexpected h1"
      (Pool_dispatch.with_dispatcher server (fun dispatch ->
           Pool_dispatch.request dispatch ~host ~port ~tag:1
           |> Effect.bind (fun response ->
                  Pool_dispatch.stats dispatch
                  |> Effect.map (fun stats -> (response, stats)))))
  in
  let server_stats = Fixture_server.stats server in
  check "unexpected h1 ALPN falls back to pool dispatch"
    (is_h1 response && stats.Pool_dispatch.h2_cells = 0
   && stats.h1_pool.opened = 1 && stats.h1_pool.idle = 1
   && server_stats.h1_opened = 1 && server_stats.h1_closed = 1)

let () =
  test_single_request ();
  test_concurrent_h2_collapse ();
  test_pending_collapse_cancels_redundant ();
  test_third_waiter_during_alpn ();
  test_unexpected_h1_pool_dispatch ();
  Printf.printf "h_d5_alpn_bootstrap stress passed\n%!"
