open Eta

type result = Done | Reset | Cancelled | Rejected | Blocked | Timed_out

let list_init = List.init

let fail msg = failwith msg

let check label cond =
  if not cond then fail ("FAIL " ^ label) else Printf.printf "PASS %s\n%!" label

let run effect =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  Runtime.run rt effect

let render_error fmt = function
  | `Admission_limited -> Format.pp_print_string fmt "Admission_limited"
  | `Cancelled -> Format.pp_print_string fmt "Cancelled"
  | `Closed -> Format.pp_print_string fmt "Closed"
  | `Flow_blocked -> Format.pp_print_string fmt "Flow_blocked"
  | `Socket_closed -> Format.pp_print_string fmt "Socket_closed"
  | `Stream_reset -> Format.pp_print_string fmt "Stream_reset"
  | `Timed_out -> Format.pp_print_string fmt "Timed_out"
  | `Writer_full -> Format.pp_print_string fmt "Writer_full"

let run_ok label effect =
  match run effect with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "%s failed: %a\n%!" label (Cause.pp render_error) cause;
      fail ("unexpected Eta failure in " ^ label)

let count value xs =
  List.fold_left (fun acc x -> if x = value then acc + 1 else acc) 0 xs

let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)

let timed f =
  let started = now_us () in
  let value = f () in
  (now_us () - started, value)

let classify_request request =
  request
  |> Effect.map (fun _ -> Done)
  |> Effect.catch (function
       | `Stream_reset -> Effect.pure Reset
       | `Admission_limited -> Effect.pure Rejected
       | err -> Effect.fail err)

let test_flow_control () =
  let blocked_conn = Fake_multiplex_connection.create ~held_tags:[ 0 ] () in
  let blocked =
    Multiplexer.with_connection ~max_streams:2 blocked_conn (fun mux ->
        Multiplexer.request ~body_chunks:16 mux ~tag:0)
    |> Effect.timeout_as (Duration.ms 20) ~on_timeout:`Flow_blocked
    |> Effect.map (fun _ -> Done)
    |> Effect.catch (function
         | `Flow_blocked -> Effect.pure Blocked
         | err -> Effect.fail err)
  in
  let blocked_result = run_ok "flow blocked" blocked in
  let blocked_data = Fake_multiplex_connection.data_writes blocked_conn in
  check "flow-control blocks at 8KB window"
    (blocked_result = Blocked && blocked_data <= 8);
  let conn = Fake_multiplex_connection.create () in
  let unblocked =
    Multiplexer.with_connection ~max_streams:2 conn (fun mux ->
        Effect.par
          (Multiplexer.request ~body_chunks:16 mux ~tag:1)
          (Effect.delay (Duration.ms 5)
             (Fake_multiplex_connection.grant_window conn ~stream_id:1
                ~bytes:8192))
        |> Effect.map fst)
    |> Effect.timeout_as (Duration.seconds 1) ~on_timeout:`Timed_out
    |> Effect.map (fun _ -> Done)
    |> Effect.catch (function
         | `Timed_out -> Effect.pure Timed_out
         | err -> Effect.fail err)
  in
  let unblocked_result = run_ok "flow unblocked" unblocked in
  let unblocked_data = Fake_multiplex_connection.data_writes conn in
  check "flow-control resumes after WINDOW_UPDATE"
    (unblocked_result = Done && unblocked_data = 16)

let test_rst_cleanup () =
  let n = 50 in
  let conn = Fake_multiplex_connection.create ~rst_after_headers:true () in
  let effect =
    Multiplexer.with_connection ~max_streams:n conn (fun mux ->
        Effect.for_each_par (list_init n Fun.id) (fun tag ->
            classify_request (Multiplexer.request mux ~tag))
        |> Effect.bind (fun results ->
               Effect.sync (fun () -> (results, Multiplexer.stats mux))))
  in
  let results, stats = run_ok "rst cleanup" effect in
  check "rst cleanup returns to baseline"
    (count Reset results = n && stats.active = 0 && stats.cancelled = 0
   && stats.live = 0 && stats.remote_resets = n)

let test_midflight_cancellation () =
  let held = list_init 10 Fun.id in
  let conn = Fake_multiplex_connection.create ~held_tags:held () in
  let effect =
    Multiplexer.with_connection ~max_streams:32 conn (fun mux ->
        Effect.for_each_par (list_init 20 Fun.id) (fun tag ->
            let request = Multiplexer.request mux ~tag in
            if tag < 10 then
              Effect.timeout_as (Duration.ms 10) ~on_timeout:`Cancelled request
              |> Effect.map (fun _ -> Done)
              |> Effect.catch (function
                   | `Cancelled -> Effect.pure Cancelled
                   | `Stream_reset -> Effect.pure Reset
                   | err -> Effect.fail err)
            else classify_request request)
        |> Effect.bind (fun results ->
               Effect.sync (fun () -> (results, Multiplexer.stats mux))))
  in
  let results, stats = run_ok "mid-flight cancellation" effect in
  let rst_writes = Fake_multiplex_connection.rst_writes conn in
  check "mid-flight cancellation queues RST and cleans streams"
    (count Cancelled results = 10 && count Done results = 10 && rst_writes >= 10
   && stats.active = 0 && stats.cancelled = 0 && stats.live = 0
   && stats.local_resets >= 10)

let test_deadlock_teardown () =
  let conn = Fake_multiplex_connection.create ~block_writes:true () in
  let teardown =
    Multiplexer.with_connection conn (fun mux ->
        Multiplexer.ping mux 1
        |> Effect.bind (fun () ->
               Fake_multiplex_connection.wait_write_started conn))
    |> Effect.map (fun () -> Done)
  in
  let guarded =
    Effect.race
      [
        teardown;
        Effect.delay (Duration.seconds 1) (Effect.pure Timed_out);
      ]
  in
  let elapsed, result = timed (fun () -> run_ok "deadlock teardown" guarded) in
  check "deadlock teardown is not extended by blocked writer"
    (result = Done && elapsed < 1_000_000)

let test_rapid_reset_admission () =
  let max_streams = 32 in
  let conn = Fake_multiplex_connection.create ~rst_after_headers:true () in
  let effect =
    Multiplexer.with_connection ~max_streams conn (fun mux ->
        Effect.for_each_par (list_init 1000 Fun.id) (fun tag ->
            classify_request (Multiplexer.request mux ~tag))
        |> Effect.bind (fun results ->
               Effect.sync (fun () -> (results, Multiplexer.stats mux))))
  in
  let results, stats = run_ok "rapid reset admission" effect in
  check "rapid reset admission counts active and cancelled"
    (stats.max_inflight <= max_streams && count Rejected results > 0
   && stats.active = 0 && stats.cancelled = 0 && stats.live = 0)

let () =
  test_flow_control ();
  test_rst_cleanup ();
  test_midflight_cancellation ();
  test_deadlock_teardown ();
  test_rapid_reset_admission ();
  Printf.printf "h_d1_dogfood_multiplex stress passed\n%!"
