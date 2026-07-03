module E = Eta.Effect

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp formatter = function
    | `Observer_failed -> Format.pp_print_string formatter "observer failed"
end

module Signal = Eta_signal.Make (Observer_error) ()

type test_error =
  [ Signal.graph_error
  | Signal.observer_read_error
  | Signal.stabilize_error
  | Signal.time_error
  | Signal.stream_error ]

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let run_ok runtime eff =
  Eta_test.Expect.expect_ok (Eta.Runtime.run runtime (widen eff))

let record updates update =
  E.sync (fun () -> updates := update :: !updates)

let test_basic_observe_stabilize_read () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 1 in
  let doubled = Signal.Var.watch source |> Signal.map (fun value -> value * 2) in
  let updates = ref [] in
  let observer =
    run_ok runtime (Signal.Observer.observe doubled (record updates))
  in
  run_ok runtime Signal.stabilize;
  run_ok runtime (Signal.Var.set source 2);
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "current" 4
    (run_ok runtime (Signal.Observer.read observer));
  (match List.rev !updates with
   | [ Signal.Initialized 2; Signal.Changed { old_value = 2; new_value = 4 } ]
     ->
       ()
   | _ -> Alcotest.fail "unexpected observer updates");
  run_ok runtime (Signal.Observer.dispose observer)

let test_bind_switch_detaches_stale_dependency () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then Signal.Var.watch left else Signal.Var.watch right)
  in
  let observer =
    run_ok runtime (Signal.Observer.observe selected (fun _ -> E.unit))
  in
  run_ok runtime Signal.stabilize;
  run_ok runtime (Signal.Var.set choose_left false);
  run_ok runtime Signal.stabilize;
  run_ok runtime (Signal.Var.set left 99);
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "right branch after left update" 20
    (run_ok runtime (Signal.Observer.read observer));
  run_ok runtime (Signal.Var.set right 21);
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "right branch update" 21
    (run_ok runtime (Signal.Observer.read observer));
  run_ok runtime (Signal.Observer.dispose observer)

let test_stream_bridge_emits_and_closes () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let observer, stream = run_ok runtime (Signal.Stream.observe signal) in
  run_ok runtime Signal.stabilize;
  let first =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  run_ok runtime (Signal.Var.set source 2);
  run_ok runtime Signal.stabilize;
  let second =
    run_ok runtime (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
  in
  run_ok runtime (Signal.Observer.dispose observer);
  let rest = run_ok runtime (Eta_stream.run_collect stream) in
  match (first, second, rest) with
  | ( [ Signal.Initialized 1 ],
      [ Signal.Changed { old_value = 1; new_value = 2 } ],
      [] ) ->
      ()
  | _ -> Alcotest.fail "unexpected stream updates"

let test_interval_catches_up_with_test_clock () =
  Eta_test.with_test_clock @@ fun _sw clock runtime ->
  let interval = run_ok runtime (Signal.Time.interval (Eta.Duration.ms 10)) in
  let observer =
    run_ok runtime (Signal.Observer.observe interval (fun _ -> E.unit))
  in
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "initial interval" 0
    (run_ok runtime (Signal.Observer.read observer));
  Eta_test.Test_clock.set_time clock 55;
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "caught up interval" 5
    (run_ok runtime (Signal.Observer.read observer));
  run_ok runtime (Signal.Observer.dispose observer)

let () =
  Alcotest.run "eta_signal_public"
    [
      ( "public",
        [
          Alcotest.test_case "observe stabilize read" `Quick
            test_basic_observe_stabilize_read;
          Alcotest.test_case "bind switch detaches stale dependency" `Quick
            test_bind_switch_detaches_stale_dependency;
          Alcotest.test_case "stream bridge emits and closes" `Quick
            test_stream_bridge_emits_and_closes;
          Alcotest.test_case "interval catches up with test clock" `Quick
            test_interval_catches_up_with_test_clock;
        ] );
    ]
