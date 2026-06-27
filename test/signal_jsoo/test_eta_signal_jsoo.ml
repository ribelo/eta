module E = Eta.Effect

module Observer_error = struct
  type t = [ `Observer_failed ]

  let pp formatter = function
    | `Observer_failed -> Format.pp_print_string formatter "observer failed"
end

module Signal = Eta_signal.Make (Observer_error) ()

type test_error =
  [ `Timeout
  | Signal.graph_error
  | Signal.observer_read_error
  | Signal.stabilize_error
  | Signal.time_error
  | Signal.stream_error ]

let pp_hidden formatter _ = Format.pp_print_string formatter "<signal-jsoo-error>"

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let ( let* ) eff f =
  E.bind (fun value -> widen (f value)) (widen eff)

let ( let+ ) eff f = E.map f (widen eff)

let fail = Eta_js_test.fail

let pp_cause cause =
  Format.asprintf "%a" (Eta.Cause.pp pp_hidden) cause

let check name condition =
  if not condition then fail name "check failed"

let check_equal_int name expected actual =
  if expected <> actual then
    fail name (Printf.sprintf "expected %d, got %d" expected actual)

let expect_ok name = function
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause -> fail name ("expected Ok, got " ^ pp_cause cause)

let expect_fail name pred = function
  | Eta.Exit.Error (Eta.Cause.Fail error) when pred error -> ()
  | Eta.Exit.Error cause ->
      fail name ("expected typed failure, got " ^ pp_cause cause)
  | Eta.Exit.Ok _ -> fail name "expected typed failure, got Ok"

let expect_die name = function
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Error cause -> fail name ("expected defect, got " ^ pp_cause cause)
  | Eta.Exit.Ok _ -> fail name "expected defect, got Ok"

let run_eta eff done_ check_result =
  let runtime = Eta_jsoo.Runtime.create () in
  Eta_jsoo.Runtime.run runtime (widen eff) ~on_result:(fun result ->
      Eta_js_test.finish done_ (fun () -> check_result result))

let record_observer events update =
  E.sync (fun () -> events := update :: !events)

let test_basic_observe_stabilize_read done_ =
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source |> Signal.map (fun value -> value * 2) in
  let events = ref [] in
  let eff =
    let* observer = Signal.Observer.observe signal (record_observer events) in
    let* () = Signal.stabilize in
    let* () = Signal.Var.set source 2 in
    let* () = Signal.stabilize in
    let* value = Signal.Observer.read observer in
    let+ () = Signal.Observer.dispose observer in
    value
  in
  run_eta eff done_ (fun result ->
      let value = expect_ok "basic observe" result in
      check_equal_int "basic observer value" 4 value;
      match List.rev !events with
      | [
          Signal.Initialized 2;
          Changed { old_value = 2; new_value = 4 };
        ] -> ()
      | _ -> fail "basic observe" "unexpected observer events")

let test_bind_branch_detaches_stale_dependency done_ =
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun use_left ->
        if use_left then Signal.Var.watch left else Signal.Var.watch right)
  in
  let eff =
    let* observer = Signal.Observer.observe selected (fun _ -> E.unit) in
    let* () = Signal.stabilize in
    let* () = Signal.Var.set choose_left false in
    let* () = Signal.stabilize in
    let* () = Signal.Var.set left 99 in
    let* () = Signal.stabilize in
    let* () = Signal.Var.set right 21 in
    let* () = Signal.stabilize in
    let* value = Signal.Observer.read observer in
    let+ () = Signal.Observer.dispose observer in
    value
  in
  run_eta eff done_ (fun result ->
      check_equal_int "bind stale dependency detached" 21
        (expect_ok "bind detach" result))

let test_failure_and_defect_propagation done_ =
  let observer_failure =
    let source = Signal.Var.create 1 in
    let* observer =
      Signal.Observer.observe (Signal.Var.watch source) (fun _ ->
          E.fail `Observer_failed)
    in
    let* exit = E.exit Signal.stabilize in
    let+ () = Signal.Observer.dispose observer in
    exit
  in
  let pure_defect =
    let source = Signal.Var.create 1 in
    let signal =
      Signal.Var.watch source
      |> Signal.map (fun value ->
             if value = 2 then failwith "signal defect";
             value)
    in
    let* observer = Signal.Observer.observe signal (fun _ -> E.unit) in
    let* () = Signal.stabilize in
    let* () = Signal.Var.set source 2 in
    let* exit = E.exit Signal.stabilize in
    let+ () = Signal.Observer.dispose observer in
    exit
  in
  let eff =
    let* observer_exit = observer_failure in
    let+ defect_exit = pure_defect in
    (observer_exit, defect_exit)
  in
  run_eta eff done_ (fun result ->
      let observer_exit, defect_exit =
        expect_ok "failure and defect propagation" result
      in
      expect_fail "observer typed failure"
        (function `Observer_error `Observer_failed -> true | _ -> false)
        observer_exit;
      expect_die "pure callback defect" defect_exit)

let test_time_nodes_require_explicit_stabilization done_ =
  let eff =
    let* interval = Signal.Time.interval (Eta.Duration.ms 1) in
    let* now = Signal.Time.now ~every:(Eta.Duration.ms 1) () in
    let combined =
      Signal.map2 (fun interval now -> (interval, now)) interval now
    in
    let* observer = Signal.Observer.observe combined (fun _ -> E.unit) in
    let* () = Signal.stabilize in
    let* initial = Signal.Observer.read observer in
    let* () = E.sleep (Eta.Duration.ms 10) in
    let* before = Signal.Observer.read observer in
    let* () = Signal.stabilize in
    let* after = Signal.Observer.read observer in
    let+ () = Signal.Observer.dispose observer in
    (initial, before, after)
  in
  run_eta eff done_ (fun result ->
      let (initial_interval, initial_now), before, (after_interval, after_now) =
        expect_ok "time explicit stabilization" result
      in
      let before_interval, before_now = before in
      check_equal_int "initial interval" 0 initial_interval;
      check_equal_int "timer read before stabilize interval" initial_interval
        before_interval;
      check_equal_int "timer read before stabilize now" initial_now before_now;
      check "interval advanced after explicit stabilize" (after_interval > 0);
      check "now did not move backwards" (after_now >= initial_now))

let test_stream_bridge_emits_and_closes done_ =
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let eff =
    let* observer, stream = Signal.Stream.observe signal in
    let* () = Signal.stabilize in
    let* first = Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect in
    let* () = Signal.Var.set source 2 in
    let* () = Signal.stabilize in
    let* second = Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect in
    let* () = Signal.Observer.dispose observer in
    let+ rest = Eta_stream.run_collect stream in
    (first, second, rest)
  in
  run_eta eff done_ (fun result ->
      match expect_ok "stream bridge" result with
      | ( [ Signal.Initialized 1 ],
          [ Signal.Changed { old_value = 1; new_value = 2 } ],
          [] ) -> ()
      | _ -> fail "stream bridge" "unexpected stream updates")

let test_interrupted_stream_backpressure_cleans_up done_ =
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let eff =
    let* observer, stream = Signal.Stream.observe ~capacity:1 signal in
    let* () = Signal.stabilize in
    let* () = Signal.Var.set source 2 in
    let* timeout_exit =
      E.exit
        (E.timeout_as (Eta.Duration.ms 5) ~on_timeout:`Timeout
           (widen Signal.stabilize))
    in
    let* after_timeout = Signal.Observer.read observer in
    let* first = Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect in
    let* () = Signal.Var.set source 3 in
    let* () = Signal.stabilize in
    let* final = Signal.Observer.read observer in
    let* second = Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect in
    let+ () = Signal.Observer.dispose observer in
    (timeout_exit, after_timeout, first, final, second)
  in
  run_eta eff done_ (fun result ->
      let timeout_exit, after_timeout, first, final, second =
        expect_ok "interrupted stream backpressure" result
      in
      expect_fail "backpressured stabilization timeout" (( = ) `Timeout)
        timeout_exit;
      check_equal_int "snapshot published before interruption" 2 after_timeout;
      check_equal_int "final snapshot after cleanup" 3 final;
      match (first, second) with
      | ( [ Signal.Initialized 1 ],
          [ Signal.Changed { old_value = 2; new_value = 3 } ] ) -> ()
      | _ ->
          fail "interrupted stream backpressure" "unexpected stream updates")

let tests =
  [
    ("basic_observe_stabilize_read", test_basic_observe_stabilize_read);
    ("bind_branch_detaches_stale_dependency", test_bind_branch_detaches_stale_dependency);
    ("failure_and_defect_propagation", test_failure_and_defect_propagation);
    ("time_nodes_require_explicit_stabilization", test_time_nodes_require_explicit_stabilization);
    ("stream_bridge_emits_and_closes", test_stream_bridge_emits_and_closes);
    ("interrupted_stream_backpressure_cleans_up", test_interrupted_stream_backpressure_cleans_up);
  ]

let () = Eta_js_test.main tests
