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

let expect_exact_runtime_mismatch name = function
  | Eta.Exit.Error (Eta.Cause.Fail `Runtime_mismatch) -> ()
  | Eta.Exit.Error cause ->
      fail name ("expected only Runtime_mismatch, got " ^ pp_cause cause)
  | Eta.Exit.Ok _ -> fail name "expected Runtime_mismatch, got Ok"

let expect_die name = function
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Error cause -> fail name ("expected defect, got " ^ pp_cause cause)
  | Eta.Exit.Ok _ -> fail name "expected defect, got Ok"

module Manual_clock = struct
  type t = {
    mutable now_ms : int;
    mutable sleepers : (int * unit Eta_jsoo.Private.resolver) list;
  }

  let create () = { now_ms = 0; sleepers = [] }
  let now_ms t () = t.now_ms
  let sleeper_count t = List.length t.sleepers

  let sleep t duration =
    let delay_ms = Eta.Duration.to_ms duration in
    if delay_ms > 0 then
      let due_ms = t.now_ms + delay_ms in
      if due_ms > t.now_ms then (
        let promise, resolver = Eta_jsoo.Private.create_promise () in
        t.sleepers <- (due_ms, resolver) :: t.sleepers;
        Eta_jsoo.Private.await
          ~on_cancel:(fun () ->
            t.sleepers <-
              List.filter
                (fun (_, candidate) -> candidate != resolver)
                t.sleepers)
          promise)

  let advance t duration =
    let target_ms = t.now_ms + Eta.Duration.to_ms duration in
    t.now_ms <- target_ms;
    let due, pending =
      List.partition (fun (due_ms, _) -> due_ms <= target_ms) t.sleepers
    in
    t.sleepers <- pending;
    List.iter (fun (_, resolver) -> Eta_jsoo.Private.resolve resolver ()) due
end

let rec wait_for_sleepers clock expected attempts =
  if Manual_clock.sleeper_count clock >= expected then E.unit
  else if attempts <= 0 then
    E.sync (fun () ->
        fail "wait for sleepers"
          (Printf.sprintf "expected %d sleepers, got %d" expected
             (Manual_clock.sleeper_count clock)))
  else
    let* () = E.yield in
    wait_for_sleepers clock expected (attempts - 1)

let run_eta ?runtime eff done_ check_result =
  let runtime =
    match runtime with
    | Some runtime -> runtime
    | None -> Eta_jsoo.Runtime.create ()
  in
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

let test_bind_selects_initialized_external_bind done_ =
  let driver = Signal.Var.create 0 in
  let leaf = Signal.Var.create 10 in
  let external_signal =
    Signal.bind (Signal.Var.watch driver) (fun offset ->
        Signal.Var.watch leaf |> Signal.map (fun value -> value + offset + 1))
  in
  let eff =
    let* external_observer =
      Signal.Observer.observe external_signal (fun _ -> E.unit)
    in
    let* () = Signal.stabilize in
    let* external_initial = Signal.Observer.read external_observer in
    let* () = Signal.Observer.dispose external_observer in
    let selected = Signal.bind (Signal.const true) (fun _ -> external_signal) in
    let* selected_observer =
      Signal.Observer.observe selected (fun _ -> E.unit)
    in
    let* () = Signal.stabilize in
    let* selected_initial = Signal.Observer.read selected_observer in
    let* () = Signal.Var.set leaf 20 in
    let* () = Signal.stabilize in
    let* leaf_update = Signal.Observer.read selected_observer in
    let* () = Signal.Var.set driver 5 in
    let* () = Signal.stabilize in
    let* driver_update = Signal.Observer.read selected_observer in
    let+ () = Signal.Observer.dispose selected_observer in
    (external_initial, selected_initial, leaf_update, driver_update)
  in
  run_eta eff done_ (fun result ->
      let external_initial, selected_initial, leaf_update, driver_update =
        expect_ok "bind selects initialized external bind" result
      in
      check_equal_int "external bind initialized" 11 external_initial;
      check_equal_int "selected initialized external bind" 11 selected_initial;
      check_equal_int "selected follows external leaf update" 21 leaf_update;
      check_equal_int "selected follows external bind switch" 26 driver_update)

let test_timer_runtime_mismatch_on_observe_with_owner_demand done_ =
  let clock_a = Manual_clock.create () in
  let clock_b = Manual_clock.create () in
  let rt_a =
    Eta_jsoo.Runtime.create ~sleep:(Manual_clock.sleep clock_a)
      ~now_ms:(Manual_clock.now_ms clock_a) ()
  in
  let rt_b =
    Eta_jsoo.Runtime.create ~sleep:(Manual_clock.sleep clock_b)
      ~now_ms:(Manual_clock.now_ms clock_b) ()
  in
  let setup =
    let* timer = Signal.Time.interval (Eta.Duration.ms 10) in
    let* keep_alive = Signal.Observer.observe timer (fun _ -> E.unit) in
    let+ () = Signal.stabilize in
    (timer, keep_alive)
  in
  Eta_jsoo.Runtime.run rt_a (widen setup) ~on_result:(function
    | Eta.Exit.Error cause ->
        Eta_js_test.finish done_ (fun () ->
            fail "timer runtime mismatch setup"
              ("expected Ok, got " ^ pp_cause cause))
    | Eta.Exit.Ok (timer, keep_alive) ->
        Eta_jsoo.Runtime.run rt_b
          (widen (Signal.Observer.observe timer (fun _ -> E.unit)))
          ~on_result:(fun mismatch_result ->
            Eta_jsoo.Runtime.run rt_a
              (widen (Signal.Observer.dispose keep_alive))
              ~on_result:(fun cleanup_result ->
                Eta_js_test.finish done_ (fun () ->
                    ignore
                      (expect_ok "timer runtime mismatch cleanup"
                         cleanup_result : unit);
                    expect_exact_runtime_mismatch
                      "observe active timer from another runtime"
                      mismatch_result))))

let test_failure_and_defect_propagation done_ =
  let observer_failure =
    let source = Signal.Var.create 1 in
    let* observer =
      Signal.Observer.observe (Signal.Var.watch source) (fun _ ->
          E.fail `Observer_failed)
    in
    let* exit = E.to_exit Signal.stabilize in
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
    let* exit = E.to_exit Signal.stabilize in
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
  let clock = Manual_clock.create () in
  let runtime =
    Eta_jsoo.Runtime.create ~sleep:(Manual_clock.sleep clock)
      ~now_ms:(Manual_clock.now_ms clock) ()
  in
  let eff =
    let* interval = Signal.Time.interval (Eta.Duration.ms 1) in
    let* now = Signal.Time.now ~every:(Eta.Duration.ms 1) () in
    let combined =
      Signal.map2 (fun interval now -> (interval, now)) interval now
    in
    let* observer = Signal.Observer.observe combined (fun _ -> E.unit) in
    let* () = Signal.stabilize in
    let* initial = Signal.Observer.read observer in
    let* () = E.sync (fun () -> Manual_clock.advance clock (Eta.Duration.ms 10)) in
    let* before = Signal.Observer.read observer in
    let* () = Signal.stabilize in
    let* after = Signal.Observer.read observer in
    let+ () = Signal.Observer.dispose observer in
    (initial, before, after)
  in
  run_eta ~runtime eff done_ (fun result ->
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

let test_stream_bridge_full_queue_drops_without_blocking done_ =
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let eff =
    let* observer, stream = Signal.Stream.observe ~capacity:1 signal in
    let* () = Signal.stabilize in
    let* () = Signal.Var.set source 2 in
    let* stabilize_exit =
      E.to_exit
        (E.timeout_as (Eta.Duration.ms 5) ~on_timeout:`Timeout
           (widen Signal.stabilize))
    in
    let* after_full_queue = Signal.Observer.read observer in
    let* first = Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect in
    let* () = Signal.Var.set source 3 in
    let* () = Signal.stabilize in
    let* final = Signal.Observer.read observer in
    let* second = Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect in
    let+ () = Signal.Observer.dispose observer in
    (stabilize_exit, after_full_queue, first, final, second)
  in
  run_eta eff done_ (fun result ->
      let stabilize_exit, after_full_queue, first, final, second =
        expect_ok "stream bridge full queue" result
      in
      ignore (expect_ok "full queue stabilization completes" stabilize_exit : unit);
      check_equal_int "snapshot advances while bridge is full" 2
        after_full_queue;
      check_equal_int "final snapshot after cleanup" 3 final;
      match (first, second) with
      | ( [ Signal.Initialized 1 ],
          [ Signal.Changed { old_value = 2; new_value = 3 } ] ) -> ()
      | _ ->
          fail "stream bridge full queue" "unexpected stream updates")

let test_invalidated_bind_rhs_observer_read done_ =
  let use_left = Signal.Var.create true in
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let captured_left = ref None in
  let selected =
    Signal.bind (Signal.Var.watch use_left) (fun active ->
        if active then (
          let branch = Signal.Var.watch left |> Signal.map (fun value -> value) in
          captured_left := Some branch;
          branch)
        else Signal.Var.watch right)
  in
  let eff =
    let* selected_observer =
      Signal.Observer.observe selected (fun _ -> E.unit)
    in
    let* () = Signal.stabilize in
    let branch =
      match !captured_left with
      | Some branch -> branch
      | None -> fail "invalidated bind RHS" "expected captured branch signal"
    in
    let* branch_observer =
      Signal.Observer.observe branch (fun _ -> E.unit)
    in
    let* () = Signal.stabilize in
    let* initial_branch = Signal.Observer.read branch_observer in
    let* () = Signal.Var.set use_left false in
    let* () = Signal.stabilize in
    let* selected_value = Signal.Observer.read selected_observer in
    let* branch_read_exit = E.to_exit (Signal.Observer.read branch_observer) in
    let* () = Signal.Observer.dispose branch_observer in
    let+ () = Signal.Observer.dispose selected_observer in
    (initial_branch, selected_value, branch_read_exit)
  in
  run_eta eff done_ (fun result ->
      let initial_branch, selected_value, branch_read_exit =
        expect_ok "invalidated bind RHS observer read" result
      in
      check_equal_int "branch initialized before invalidation" 10
        initial_branch;
      check_equal_int "selected switched to right branch" 20 selected_value;
      expect_fail "branch observer read invalidated"
        (function `Invalid_scope -> true | _ -> false)
        branch_read_exit)

let test_interval_dispose_stops_sleeping_daemon done_ =
  let clock = Manual_clock.create () in
  let runtime =
    Eta_jsoo.Runtime.create ~sleep:(Manual_clock.sleep clock)
      ~now_ms:(Manual_clock.now_ms clock) ()
  in
  let eff =
    let* interval = Signal.Time.interval (Eta.Duration.ms 10) in
    let* observer = Signal.Observer.observe interval (fun _ -> E.unit) in
    let* () = wait_for_sleepers clock 1 20 in
    let* () = Signal.Observer.dispose observer in
    let* () =
      E.sync (fun () -> Manual_clock.advance clock (Eta.Duration.ms 10))
    in
    let* () = E.yield in
    let+ sleepers = E.sync (fun () -> Manual_clock.sleeper_count clock) in
    sleepers
  in
  run_eta ~runtime eff done_ (fun result ->
      check_equal_int "disposed interval has no sleeping daemon" 0
        (expect_ok "interval dispose stops daemon" result))

let test_interval_restarts_after_reobserve done_ =
  let clock = Manual_clock.create () in
  let runtime =
    Eta_jsoo.Runtime.create ~sleep:(Manual_clock.sleep clock)
      ~now_ms:(Manual_clock.now_ms clock) ()
  in
  let eff =
    let* interval = Signal.Time.interval (Eta.Duration.ms 10) in
    let* first_observer =
      Signal.Observer.observe interval (fun _ -> E.unit)
    in
    let* () = wait_for_sleepers clock 1 20 in
    let* () = Signal.Observer.dispose first_observer in
    let* () =
      E.sync (fun () -> Manual_clock.advance clock (Eta.Duration.ms 10))
    in
    let* () = E.yield in
    let* sleepers_after_dispose =
      E.sync (fun () -> Manual_clock.sleeper_count clock)
    in
    let* second_observer =
      Signal.Observer.observe interval (fun _ -> E.unit)
    in
    let* () = wait_for_sleepers clock 1 20 in
    let* () = Signal.stabilize in
    let* initial = Signal.Observer.read second_observer in
    let* () =
      E.sync (fun () -> Manual_clock.advance clock (Eta.Duration.ms 10))
    in
    let* () = E.yield in
    let* () = Signal.stabilize in
    let* after_restart = Signal.Observer.read second_observer in
    let+ () = Signal.Observer.dispose second_observer in
    (sleepers_after_dispose, initial, after_restart)
  in
  run_eta ~runtime eff done_ (fun result ->
      let sleepers_after_dispose, initial, after_restart =
        expect_ok "interval restarts after reobserve" result
      in
      check_equal_int "disposed timer stopped before reobserve" 0
        sleepers_after_dispose;
      check_equal_int "reobserved interval starts from cached value" 0 initial;
      check_equal_int "reobserved interval ticks after fresh interval" 1
        after_restart)

let test_stream_invalid_scope_closes_with_error done_ =
  let use_branch = Signal.Var.create true in
  let branch_source = Signal.Var.create 0 in
  let captured = ref None in
  let selected =
    Signal.bind (Signal.Var.watch use_branch) (fun active ->
        if active then (
          let branch = Signal.Var.watch branch_source in
          captured := Some branch;
          branch)
        else Signal.const 42)
  in
  let eff =
    let* selected_observer =
      Signal.Observer.observe selected (fun _ -> E.unit)
    in
    let* () = Signal.stabilize in
    let branch =
      match !captured with
      | Some branch -> branch
      | None ->
          fail "stream invalid scope" "expected captured branch signal"
    in
    let* branch_observer, stream =
      Signal.Stream.observe ~capacity:4 branch
    in
    let* () = Signal.stabilize in
    let* () = Signal.Var.set branch_source 1 in
    let* () = Signal.stabilize in
    let* () = Signal.Var.set use_branch false in
    let* () = Signal.stabilize in
    let* buffered =
      Eta_stream.Stream.take 2 stream |> Eta_stream.run_collect
    in
    let* stream_exit = E.to_exit (Eta_stream.run_collect stream) in
    let* branch_read_exit = E.to_exit (Signal.Observer.read branch_observer) in
    let* selected_value = Signal.Observer.read selected_observer in
    let+ () = Signal.Observer.dispose selected_observer in
    (buffered, stream_exit, branch_read_exit, selected_value)
  in
  run_eta eff done_ (fun result ->
      let buffered, stream_exit, branch_read_exit, selected_value =
        expect_ok "stream invalid scope closes with error" result
      in
      (match buffered with
       | [
        Signal.Initialized 0;
        Signal.Changed { old_value = 0; new_value = 1 };
       ] ->
           ()
       | _ ->
           fail "stream invalid scope"
             "expected buffered branch updates before invalid-scope error");
      expect_fail "stream closes with invalid scope"
        (function `Invalid_scope -> true | _ -> false)
        stream_exit;
      expect_fail "stream observer read invalidated"
        (function `Invalid_scope -> true | _ -> false)
        branch_read_exit;
      check_equal_int "selected switched after stream invalidation" 42
        selected_value)

let test_observer_callback_timeout_releases_stabilization done_ =
  let clock = Manual_clock.create () in
  let runtime =
    Eta_jsoo.Runtime.create ~sleep:(Manual_clock.sleep clock)
      ~now_ms:(Manual_clock.now_ms clock) ()
  in
  let source = Signal.Var.create 0 in
  let block_next = ref false in
  let callbacks = ref 0 in
  let callback _ =
    incr callbacks;
    if !block_next then (
      block_next := false;
      E.seq
        E.never
        (E.sync (fun () -> Manual_clock.advance clock (Eta.Duration.ms 5))))
    else E.unit
  in
  let eff =
    let* observer = Signal.Observer.observe (Signal.Var.watch source) callback in
    let* () = Signal.stabilize in
    let* () = Signal.Var.set source 1 in
    let* () = E.sync (fun () -> block_next := true) in
    let* timeout_exit =
      E.to_exit
        (E.timeout_as (Eta.Duration.ms 5) ~on_timeout:`Timeout
           (widen Signal.stabilize))
    in
    let* () = Signal.stabilize in
    let* value = Signal.Observer.read observer in
    let* callback_count = E.sync (fun () -> !callbacks) in
    let+ () = Signal.Observer.dispose observer in
    (timeout_exit, value, callback_count)
  in
  run_eta ~runtime eff done_ (fun result ->
      let timeout_exit, value, callback_count =
        expect_ok "observer callback timeout cleanup" result
      in
      expect_fail "interrupted stabilization times out"
        (function `Timeout -> true | _ -> false)
        timeout_exit;
      check_equal_int "stabilization retry publishes value" 1 value;
      check_equal_int "callback retried after timeout" 3 callback_count)

let tests =
  [
    ("basic_observe_stabilize_read", test_basic_observe_stabilize_read);
    ("bind_branch_detaches_stale_dependency", test_bind_branch_detaches_stale_dependency);
    ( "bind_selects_initialized_external_bind",
      test_bind_selects_initialized_external_bind );
    ( "timer_runtime_mismatch_on_observe_with_owner_demand",
      test_timer_runtime_mismatch_on_observe_with_owner_demand );
    ("failure_and_defect_propagation", test_failure_and_defect_propagation);
    ("time_nodes_require_explicit_stabilization", test_time_nodes_require_explicit_stabilization);
    ("stream_bridge_emits_and_closes", test_stream_bridge_emits_and_closes);
    ("stream_bridge_full_queue_drops_without_blocking", test_stream_bridge_full_queue_drops_without_blocking);
    ("invalidated_bind_rhs_observer_read", test_invalidated_bind_rhs_observer_read);
    ("interval_dispose_stops_sleeping_daemon", test_interval_dispose_stops_sleeping_daemon);
    ("interval_restarts_after_reobserve", test_interval_restarts_after_reobserve);
    ("stream_invalid_scope_closes_with_error", test_stream_invalid_scope_closes_with_error);
    ("observer_callback_timeout_releases_stabilization", test_observer_callback_timeout_releases_stabilization);
  ]

let () = Eta_js_test.main tests
