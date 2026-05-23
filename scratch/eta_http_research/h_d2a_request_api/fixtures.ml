open Eta

module Api = Request_api

let fail msg = failwith msg

let check label cond =
  if cond then Printf.printf "PASS %s\n%!" label else fail ("FAIL " ^ label)

let render_error fmt err = Format.pp_print_string fmt (Error.to_string err)

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

let render_pool_error fmt = function
  | `Admission_limited -> Format.pp_print_string fmt "Admission_limited"
  | `Closed -> Format.pp_print_string fmt "Closed"
  | `Connection_cancelled -> Format.pp_print_string fmt "Connection_cancelled"
  | `Pool_shutdown -> Format.pp_print_string fmt "Pool_shutdown"
  | `Pool_shutdown_timeout -> Format.pp_print_string fmt "Pool_shutdown_timeout"
  | `Socket_closed -> Format.pp_print_string fmt "Socket_closed"
  | `Stream_reset -> Format.pp_print_string fmt "Stream_reset"
  | `Writer_full -> Format.pp_print_string fmt "Writer_full"

let run_ok_h5 label effect =
  match run effect with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "%s failed: %a\n%!" label (Cause.pp render_pool_error)
        cause;
      fail ("unexpected Eta failure in " ^ label)

let ( let* ) effect f = Effect.bind f effect

let exercise create =
  let* client = create () in
  let* trace = Caller_demo.run client in
  let* stats = Api.Client.stats client in
  let* () = Api.Client.shutdown client in
  Effect.pure (trace, stats)

let open_body_probe create =
  let* client = create () in
  let req = Api.Request.make "GET" "/stream" in
  let* response = Api.request client req in
  let* open_stats = Api.Client.stats client in
  let* () = Api.Stream.discard response.body in
  let* closed_stats = Api.Client.stats client in
  let* () = Api.Client.shutdown client in
  Effect.pure (open_stats, closed_stats)

let print_stats label stats =
  Api.Stats.to_lines stats
  |> List.iter (fun line -> Printf.printf "%s %s\n%!" label line)

let test_caller_trace_identical () =
  let h1_trace, h1_stats = run_ok "h1 caller" (exercise H1_internal.create) in
  let h2_trace, h2_stats =
    run_ok "h2 caller" (exercise (fun () -> H2_internal.create ()))
  in
  List.iter (Printf.printf "TRACE %s\n%!") h1_trace;
  print_stats "H1" h1_stats;
  print_stats "H2" h2_stats;
  check "same caller trace across h1 and h2" (h1_trace = h2_trace);
  check "h1 releases every response body"
    (h1_stats.Api.Stats.active = 0 && h1_stats.released = 4);
  check "h2 releases every stream permit"
    (h2_stats.Api.Stats.active = 0 && h2_stats.released = 4)

let test_open_body_holds_lease () =
  let h1_open, h1_closed =
    run_ok "h1 open body" (open_body_probe H1_internal.create)
  in
  let h2_open, h2_closed =
    run_ok "h2 open body" (open_body_probe (fun () -> H2_internal.create ()))
  in
  check "h1 pool checkout is held while body is open"
    (h1_open.Api.Stats.active = 1 && h1_closed.active = 0);
  check "h2 stream permit is held while body is open"
    (h2_open.Api.Stats.active = 1 && h2_closed.active = 0)

let test_h_d5_private_library_still_passes () =
  let response, stats =
    run_ok_h5 "h-d5 private library"
      (Pool_dispatch.with_dispatcher
         (Fixture_server.create Pending_connection.H2)
         (fun dispatch ->
           Pool_dispatch.request dispatch ~host:"example.test" ~port:443 ~tag:1
           |> Effect.bind (fun response ->
                  Pool_dispatch.stats dispatch
                  |> Effect.map (fun stats -> (response, stats)))))
  in
  let h2 = match response with `H2 _ -> true | `H1 _ -> false in
  check "h-d5 library exposes ALPN dispatcher for reuse"
    (h2 && stats.Pool_dispatch.h2_cells = 1 && stats.h2_requests = 1)

let () =
  test_caller_trace_identical ();
  test_open_body_holds_lease ();
  test_h_d5_private_library_still_passes ();
  Printf.printf "h_d2a_request_api fixtures passed\n%!"
