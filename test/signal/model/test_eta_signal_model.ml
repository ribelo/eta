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
  | Signal.stream_error
  | `Update_failed ]

type observed_update =
  | Initialized of int
  | Changed of int * int

type op =
  | Set_a of int
  | Set_b of int
  | Choose_a of bool
  | Stabilize
  | Read

type model = {
  mutable pending_a : int;
  mutable pending_b : int;
  mutable pending_choose_a : bool;
  mutable committed_a : int;
  mutable committed_b : int;
  mutable committed_choose_a : bool;
  mutable observer_current : int option;
  mutable observed_updates : observed_update list;
}

let pp_hidden formatter _ = Format.pp_print_string formatter "<signal-error>"

let widen (eff : ('a, [< test_error ]) E.t) : ('a, test_error) E.t =
  E.map_error (fun error -> (error :> test_error)) eff

let run_ok runtime eff =
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ok, got %a" (Eta.Cause.pp pp_hidden) cause

let wait_until label predicate =
  let rec loop attempts =
    if predicate () then ()
    else if attempts = 0 then Alcotest.failf "timed out waiting for %s" label
    else (
      Eta_test.Async.yield ();
      loop (attempts - 1))
  in
  loop 200

let expect_observer_failed label runtime eff =
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Error (Eta.Cause.Fail (`Observer_error `Observer_failed)) -> ()
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected observer failure, got Ok" label
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected observer failure, got %a" label
        (Eta.Cause.pp pp_hidden) cause

let expect_graph_error label pred runtime eff =
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Error (Eta.Cause.Fail err) when pred err -> ()
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected graph failure, got Ok" label
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected graph failure, got %a" label
        (Eta.Cause.pp pp_hidden) cause

let expect_die label runtime eff =
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected die, got Ok" label
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected die, got %a" label
        (Eta.Cause.pp pp_hidden) cause

let expect_update_failed label runtime eff =
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Error (Eta.Cause.Fail `Update_failed) -> ()
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected update failure, got Ok" label
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected update failure, got %a" label
        (Eta.Cause.pp pp_hidden) cause

let expect_uninitialized_observer label runtime eff =
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Error (Eta.Cause.Fail `Uninitialized_observer) -> ()
  | Eta.Exit.Ok _ ->
      Alcotest.failf "%s: expected uninitialized observer, got Ok" label
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected uninitialized observer, got %a" label
        (Eta.Cause.pp pp_hidden) cause

let expect_disposed_observer label runtime eff =
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Error (Eta.Cause.Fail `Disposed_observer) -> ()
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected disposed observer, got Ok" label
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected disposed observer, got %a" label
        (Eta.Cause.pp pp_hidden) cause

let pp_observed_update formatter = function
  | Initialized value -> Format.fprintf formatter "Initialized %d" value
  | Changed (old_value, new_value) ->
      Format.fprintf formatter "Changed { old_value = %d; new_value = %d }"
        old_value new_value

let observed_update =
  Alcotest.testable pp_observed_update (fun left right -> left = right)

let observed_of_signal_update = function
  | Signal.Initialized value -> Initialized value
  | Signal.Changed { old_value; new_value } -> Changed (old_value, new_value)

let pp_op formatter = function
  | Set_a value -> Format.fprintf formatter "Set_a %d" value
  | Set_b value -> Format.fprintf formatter "Set_b %d" value
  | Choose_a value -> Format.fprintf formatter "Choose_a %b" value
  | Stabilize -> Format.pp_print_string formatter "Stabilize"
  | Read -> Format.pp_print_string formatter "Read"

let model_value model =
  let selected =
    if model.committed_choose_a then model.committed_a else model.committed_b
  in
  ((model.committed_a + model.committed_b) * 10) + selected

let create_model () =
  {
    pending_a = 1;
    pending_b = 10;
    pending_choose_a = true;
    committed_a = 1;
    committed_b = 10;
    committed_choose_a = true;
    observer_current = None;
    observed_updates = [];
  }

let stabilize_model model =
  model.committed_a <- model.pending_a;
  model.committed_b <- model.pending_b;
  model.committed_choose_a <- model.pending_choose_a;
  let next = model_value model in
  let update =
    match model.observer_current with
    | None -> Some (Initialized next)
    | Some current ->
        if current = next then None else Some (Changed (current, next))
  in
  model.observer_current <- Some next;
  match update with
  | None -> ()
  | Some update ->
      model.observed_updates <- update :: model.observed_updates

let check_observed_updates label model actual_updates =
  Alcotest.(check (list observed_update))
    label (List.rev model.observed_updates) (List.rev !actual_updates)

let check_read label runtime read_current model =
  match model.observer_current with
  | None -> ()
  | Some expected ->
      Alcotest.(check int) label expected (run_ok runtime read_current)

let generate_trace ~seed ~steps =
  let random = Random.State.make [| seed |] in
  let next_value () = Random.State.int random 9 - 4 in
  let next_op index =
    if index mod 7 = 0 then Stabilize
    else
      match Random.State.int random 10 with
      | 0 | 1 | 2 -> Set_a (next_value ())
      | 3 | 4 | 5 -> Set_b (next_value ())
      | 6 | 7 -> Choose_a (Random.State.bool random)
      | 8 -> Read
      | _ -> Stabilize
  in
  let rec loop index acc =
    if index = steps then List.rev (Stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  Stabilize :: loop 1 []

let run_trace name ops =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source_a = Signal.Var.create 1 in
  let source_b = Signal.Var.create 10 in
  let choose_a = Signal.Var.create true in
  let sum =
    Signal.map2
      (fun left right -> left + right)
      (Signal.Var.watch source_a)
      (Signal.Var.watch source_b)
  in
  let selected =
    Signal.bind (Signal.Var.watch choose_a) (fun use_a ->
        if use_a then Signal.Var.watch source_a else Signal.Var.watch source_b)
  in
  let output =
    Signal.map2 (fun total selected -> (total * 10) + selected) sum selected
  in
  let actual_updates = ref [] in
  let record update =
    E.sync (fun () ->
        actual_updates := observed_of_signal_update update :: !actual_updates)
  in
  let observer = run_ok runtime (Signal.Observer.observe output record) in
  let model = create_model () in
  List.iteri
    (fun index op ->
      let label = Format.asprintf "%s step %d %a" name index pp_op op in
      match op with
      | Set_a value ->
          model.pending_a <- value;
          run_ok runtime (Signal.Var.set source_a value)
      | Set_b value ->
          model.pending_b <- value;
          run_ok runtime (Signal.Var.set source_b value)
      | Choose_a value ->
          model.pending_choose_a <- value;
          run_ok runtime (Signal.Var.set choose_a value)
      | Stabilize ->
          stabilize_model model;
          run_ok runtime Signal.stabilize;
          check_observed_updates label model actual_updates
      | Read ->
          check_read label runtime (Signal.Observer.read observer) model)
    ops;
  run_ok runtime (Signal.Observer.dispose observer)

let test_scripted_trace_matches_model () =
  run_trace "scripted"
    [
      Stabilize;
      Set_a 2;
      Set_a 3;
      Set_b 10;
      Stabilize;
      Read;
      Choose_a false;
      Set_a 99;
      Stabilize;
      Read;
      Set_b 4;
      Set_b 5;
      Choose_a true;
      Stabilize;
      Read;
    ]

let test_randomized_trace_matches_model () =
  List.iter
    (fun seed ->
      run_trace (Format.asprintf "seed-%d" seed) (generate_trace ~seed ~steps:80))
    [ 11; 29; 47; 83 ]

type timer_model_op =
  | Timer_advance of int
  | Timer_stabilize
  | Timer_observe_now
  | Timer_dispose_now
  | Timer_read_now
  | Timer_observe_after
  | Timer_dispose_after
  | Timer_read_after
  | Timer_observe_interval
  | Timer_dispose_interval
  | Timer_read_interval

let pp_timer_model_op formatter = function
  | Timer_advance ms -> Format.fprintf formatter "Timer_advance %d" ms
  | Timer_stabilize -> Format.pp_print_string formatter "Timer_stabilize"
  | Timer_observe_now -> Format.pp_print_string formatter "Timer_observe_now"
  | Timer_dispose_now -> Format.pp_print_string formatter "Timer_dispose_now"
  | Timer_read_now -> Format.pp_print_string formatter "Timer_read_now"
  | Timer_observe_after -> Format.pp_print_string formatter "Timer_observe_after"
  | Timer_dispose_after -> Format.pp_print_string formatter "Timer_dispose_after"
  | Timer_read_after -> Format.pp_print_string formatter "Timer_read_after"
  | Timer_observe_interval ->
      Format.pp_print_string formatter "Timer_observe_interval"
  | Timer_dispose_interval ->
      Format.pp_print_string formatter "Timer_dispose_interval"
  | Timer_read_interval ->
      Format.pp_print_string formatter "Timer_read_interval"

type 'a timer_observer_state = {
  mutable timer_observer : 'a Signal.observer option;
  mutable timer_current : 'a option;
}

let create_timer_observer_state () =
  { timer_observer = None; timer_current = None }

let timer_model_observe runtime signal state =
  match state.timer_observer with
  | Some _ -> ()
  | None ->
      state.timer_observer <-
        Some (run_ok runtime (Signal.Observer.observe signal (fun _ -> E.unit)));
      state.timer_current <- None

let timer_model_dispose runtime state =
  match state.timer_observer with
  | None -> ()
  | Some observer ->
      run_ok runtime (Signal.Observer.dispose observer);
      state.timer_observer <- None;
      state.timer_current <- None

let timer_model_stabilize_state state value =
  match state.timer_observer with
  | None -> ()
  | Some _ -> state.timer_current <- Some value

let timer_model_read runtime label state testable =
  match (state.timer_observer, state.timer_current) with
  | None, _ -> ()
  | Some observer, None ->
      expect_uninitialized_observer label runtime (Signal.Observer.read observer)
  | Some observer, Some expected ->
      Alcotest.check testable label expected
        (run_ok runtime (Signal.Observer.read observer))

let generate_timer_model_ops ~seed ~steps =
  let random = Random.State.make [| seed; steps; 53 |] in
  let next_op index =
    if index mod 6 = 0 then Timer_stabilize
    else
      match Random.State.int random 20 with
      | 0 | 1 | 2 -> Timer_advance (1 + Random.State.int random 9)
      | 3 | 4 -> Timer_observe_now
      | 5 -> Timer_dispose_now
      | 6 | 7 -> Timer_read_now
      | 8 | 9 -> Timer_observe_after
      | 10 -> Timer_dispose_after
      | 11 | 12 -> Timer_read_after
      | 13 | 14 -> Timer_observe_interval
      | 15 -> Timer_dispose_interval
      | 16 | 17 -> Timer_read_interval
      | _ -> Timer_stabilize
  in
  let scripted =
    [
      Timer_observe_now;
      Timer_observe_after;
      Timer_observe_interval;
      Timer_stabilize;
      Timer_read_now;
      Timer_read_after;
      Timer_read_interval;
      Timer_advance 5;
      Timer_stabilize;
      Timer_read_now;
      Timer_read_after;
      Timer_read_interval;
      Timer_advance 5;
      Timer_stabilize;
      Timer_read_now;
      Timer_read_after;
      Timer_read_interval;
      Timer_dispose_interval;
      Timer_advance 5;
      Timer_observe_interval;
      Timer_stabilize;
      Timer_read_interval;
      Timer_advance 5;
      Timer_stabilize;
      Timer_read_interval;
      Timer_advance 5;
      Timer_stabilize;
      Timer_read_interval;
      Timer_dispose_now;
      Timer_dispose_after;
      Timer_dispose_interval;
      Timer_advance 7;
      Timer_observe_now;
      Timer_observe_after;
      Timer_observe_interval;
      Timer_read_now;
      Timer_read_after;
      Timer_read_interval;
      Timer_stabilize;
      Timer_read_now;
      Timer_read_after;
      Timer_read_interval;
    ]
  in
  let rec loop index acc =
    if index = steps then List.rev (Timer_stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  scripted @ loop 1 []

let run_timer_model_trace name ~seed =
  Eta_test.with_test_clock @@ fun _sw clock runtime ->
  let clock_ms = ref 0 in
  let now_signal =
    run_ok runtime (Signal.Time.now ~every:(Eta.Duration.ms 5) ())
    |> Signal.map Signal.Time.to_ms
  in
  let after_signal =
    run_ok runtime
      (Signal.Time.after ~every:(Eta.Duration.ms 5) (Eta.Duration.ms 10))
  in
  let interval_signal =
    run_ok runtime (Signal.Time.interval (Eta.Duration.ms 10))
  in
  let now_state = create_timer_observer_state () in
  let after_state = create_timer_observer_state () in
  let interval_state = create_timer_observer_state () in
  let interval_next_due = ref None in
  let interval_value = ref 0 in
  let after_value () = !clock_ms >= 10 in
  let observe_interval () =
    match interval_state.timer_observer with
    | Some _ -> ()
    | None ->
        timer_model_observe runtime interval_signal interval_state;
        interval_next_due := Some (!clock_ms + 10)
  in
  let dispose_interval () =
    timer_model_dispose runtime interval_state;
    interval_next_due := None
  in
  let stabilize_interval () =
    match interval_state.timer_observer with
    | None -> ()
    | Some _ ->
        (match !interval_next_due with
         | None -> interval_next_due := Some (!clock_ms + 10)
         | Some next_due when !clock_ms >= next_due ->
             let missed = ((!clock_ms - next_due) / 10) + 1 in
             interval_value := !interval_value + missed;
             interval_next_due := Some (next_due + (missed * 10))
         | Some _ -> ());
        timer_model_stabilize_state interval_state !interval_value
  in
  let ops = generate_timer_model_ops ~seed ~steps:80 in
  Fun.protect
    ~finally:(fun () ->
      timer_model_dispose runtime now_state;
      timer_model_dispose runtime after_state;
      dispose_interval ())
    (fun () ->
      List.iteri
        (fun index op ->
          let label =
            Format.asprintf "%s step %d %a" name index pp_timer_model_op op
          in
          match op with
          | Timer_advance ms ->
              clock_ms := !clock_ms + ms;
              Eta_test.Test_clock.adjust clock (Eta.Duration.ms ms);
              Eta_test.Async.yield ()
          | Timer_stabilize ->
              run_ok runtime Signal.stabilize;
              timer_model_stabilize_state now_state !clock_ms;
              timer_model_stabilize_state after_state (after_value ());
              stabilize_interval ()
          | Timer_observe_now ->
              timer_model_observe runtime now_signal now_state
          | Timer_dispose_now ->
              timer_model_dispose runtime now_state
          | Timer_read_now ->
              timer_model_read runtime label now_state Alcotest.int
          | Timer_observe_after ->
              timer_model_observe runtime after_signal after_state
          | Timer_dispose_after ->
              timer_model_dispose runtime after_state
          | Timer_read_after ->
              timer_model_read runtime label after_state Alcotest.bool
          | Timer_observe_interval ->
              observe_interval ()
          | Timer_dispose_interval ->
              dispose_interval ()
          | Timer_read_interval ->
              timer_model_read runtime label interval_state Alcotest.int)
        ops)

let test_time_now_after_interval_lifecycle_trace_matches_model () =
  List.iter
    (fun seed ->
      run_timer_model_trace
        (Format.asprintf "timer-lifecycle-seed-%d" seed)
        ~seed)
    [ 19; 43; 71; 131 ]

type timer_bind_choice =
  | Bind_inactive
  | Bind_now
  | Bind_after
  | Bind_interval

type timer_bind_op =
  | Timer_bind_select of timer_bind_choice
  | Timer_bind_advance of int
  | Timer_bind_stabilize
  | Timer_bind_read

let pp_timer_bind_choice formatter = function
  | Bind_inactive -> Format.pp_print_string formatter "inactive"
  | Bind_now -> Format.pp_print_string formatter "now"
  | Bind_after -> Format.pp_print_string formatter "after"
  | Bind_interval -> Format.pp_print_string formatter "interval"

let pp_timer_bind_op formatter = function
  | Timer_bind_select choice ->
      Format.fprintf formatter "Timer_bind_select %a" pp_timer_bind_choice
        choice
  | Timer_bind_advance ms ->
      Format.fprintf formatter "Timer_bind_advance %d" ms
  | Timer_bind_stabilize ->
      Format.pp_print_string formatter "Timer_bind_stabilize"
  | Timer_bind_read -> Format.pp_print_string formatter "Timer_bind_read"

let generate_timer_bind_ops ~seed ~steps =
  let random = Random.State.make [| seed; steps; 79 |] in
  let next_choice () =
    match Random.State.int random 4 with
    | 0 -> Bind_inactive
    | 1 -> Bind_now
    | 2 -> Bind_after
    | _ -> Bind_interval
  in
  let next_op index =
    if index mod 5 = 0 then Timer_bind_stabilize
    else
      match Random.State.int random 10 with
      | 0 | 1 | 2 -> Timer_bind_select (next_choice ())
      | 3 | 4 | 5 -> Timer_bind_advance (1 + Random.State.int random 12)
      | 6 | 7 -> Timer_bind_read
      | _ -> Timer_bind_stabilize
  in
  let scripted =
    [
      Timer_bind_stabilize;
      Timer_bind_read;
      Timer_bind_select Bind_interval;
      Timer_bind_stabilize;
      Timer_bind_read;
      Timer_bind_advance 10;
      Timer_bind_stabilize;
      Timer_bind_read;
      Timer_bind_select Bind_inactive;
      Timer_bind_stabilize;
      Timer_bind_advance 10;
      Timer_bind_stabilize;
      Timer_bind_read;
      Timer_bind_select Bind_interval;
      Timer_bind_stabilize;
      Timer_bind_read;
      Timer_bind_advance 5;
      Timer_bind_stabilize;
      Timer_bind_read;
      Timer_bind_advance 5;
      Timer_bind_stabilize;
      Timer_bind_read;
      Timer_bind_select Bind_inactive;
      Timer_bind_stabilize;
      Timer_bind_advance 20;
      Timer_bind_select Bind_now;
      Timer_bind_stabilize;
      Timer_bind_read;
      Timer_bind_select Bind_after;
      Timer_bind_stabilize;
      Timer_bind_read;
    ]
  in
  let rec loop index acc =
    if index = steps then List.rev (Timer_bind_stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  scripted @ loop 1 []

let run_timer_bind_model_trace name ~seed =
  Eta_test.with_test_clock @@ fun _sw clock runtime ->
  let clock_ms = ref 0 in
  let pending_choice = ref Bind_inactive in
  let active_choice = ref Bind_inactive in
  let interval_next_due = ref None in
  let interval_value = ref 0 in
  let observer_current = ref None in
  let timer_choice = Signal.Var.create Bind_inactive in
  let now_timer =
    run_ok runtime (Signal.Time.now ~every:(Eta.Duration.ms 5) ())
    |> Signal.map Signal.Time.to_ms
  in
  let after_timer =
    run_ok runtime
      (Signal.Time.after ~every:(Eta.Duration.ms 5) (Eta.Duration.ms 10))
    |> Signal.map (fun due ->
           if !clock_ms >= 10 && not due then
             failwith "stale deadline reached model";
           if due then 1 else 0)
  in
  let interval_timer =
    run_ok runtime (Signal.Time.interval (Eta.Duration.ms 10))
  in
  let selected =
    Signal.bind (Signal.Var.watch timer_choice) (function
      | Bind_inactive -> Signal.const (-1)
      | Bind_now -> now_timer
      | Bind_after -> after_timer
      | Bind_interval -> interval_timer)
  in
  let observer =
    run_ok runtime (Signal.Observer.observe selected (fun _ -> E.unit))
  in
  let check_demand label =
    if !active_choice = Bind_interval then (
      wait_until (label ^ " active timer sleeper") (fun () ->
          Eta_test.Test_clock.sleeper_count clock >= 1);
      let sleepers = Eta_test.Test_clock.sleeper_count clock in
      Alcotest.(check bool)
        (label ^ " active timer has one live sleeper")
        true (sleepers >= 1))
  in
  let expected_value () =
    match !active_choice with
    | Bind_inactive -> -1
    | Bind_now -> !clock_ms
    | Bind_after -> if !clock_ms >= 10 then 1 else 0
    | Bind_interval -> !interval_value
  in
  let model_stabilize label =
    run_ok runtime Signal.stabilize;
    let was_interval_active = !active_choice = Bind_interval in
    let previous_next_due = !interval_next_due in
    let next_due_after_catchup =
      match previous_next_due with
      | Some next_due when was_interval_active && !clock_ms >= next_due ->
          let missed = ((!clock_ms - next_due) / 10) + 1 in
          interval_value := !interval_value + missed;
          Some (next_due + (missed * 10))
      | _ -> previous_next_due
    in
    active_choice := !pending_choice;
    if !active_choice = Bind_interval then (
      if not was_interval_active then interval_next_due := Some (!clock_ms + 10)
      else
        match next_due_after_catchup with
        | None -> interval_next_due := Some (!clock_ms + 10)
        | Some next_due -> interval_next_due := Some next_due)
    else (
      interval_next_due := None;
      ignore next_due_after_catchup);
    let expected = expected_value () in
    observer_current := Some expected;
    Alcotest.(check int) (label ^ " selected value") expected
      (run_ok runtime (Signal.Observer.read observer));
    if !active_choice = Bind_interval || not was_interval_active then
      check_demand label
  in
  Fun.protect
    ~finally:(fun () -> run_ok runtime (Signal.Observer.dispose observer))
    (fun () ->
      generate_timer_bind_ops ~seed ~steps:90
      |> List.iteri (fun index op ->
             let label =
               Format.asprintf "%s step %d %a" name index pp_timer_bind_op op
             in
             match op with
             | Timer_bind_select choice ->
                 pending_choice := choice;
                 run_ok runtime (Signal.Var.set timer_choice choice)
             | Timer_bind_advance ms ->
                 clock_ms := !clock_ms + ms;
                 Eta_test.Test_clock.adjust clock (Eta.Duration.ms ms);
                 Eta_test.Async.yield ();
                 check_demand label
             | Timer_bind_stabilize -> model_stabilize label
             | Timer_bind_read -> (
                 match !observer_current with
                 | None ->
                     expect_uninitialized_observer label runtime
                       (Signal.Observer.read observer)
                 | Some expected ->
                     Alcotest.(check int) label expected
                       (run_ok runtime (Signal.Observer.read observer)))))

let test_time_bind_demand_trace_matches_model () =
  List.iter
    (fun seed ->
      run_timer_bind_model_trace
        (Format.asprintf "timer-bind-seed-%d" seed)
        ~seed)
    [ 23; 41; 89; 167 ]

let test_coalesced_sets_match_model () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 0 in
  let recomputes = ref 0 in
  let signal =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           incr recomputes;
           value * 2)
  in
  let updates = ref [] in
  let record update =
    E.sync (fun () ->
        updates := observed_of_signal_update update :: !updates)
  in
  let observer = run_ok runtime (Signal.Observer.observe signal record) in
  let model_pending = ref 0 in
  let model_current = ref None in
  let model_recomputes = ref 0 in
  let model_updates = ref [] in
  let stabilize_model () =
    incr model_recomputes;
    let next = !model_pending * 2 in
    let update =
      match !model_current with
      | None -> Some (Initialized next)
      | Some current ->
          if current = next then None else Some (Changed (current, next))
    in
    model_current := Some next;
    Option.iter (fun update -> model_updates := update :: !model_updates) update
  in
  let set value =
    model_pending := value;
    run_ok runtime (Signal.Var.set source value)
  in
  let check label =
    Alcotest.(check int)
      (label ^ " recomputes") !model_recomputes !recomputes;
    Alcotest.(check (list observed_update))
      (label ^ " updates") (List.rev !model_updates) (List.rev !updates);
    match !model_current with
    | None -> ()
    | Some expected ->
        Alcotest.(check int) (label ^ " read") expected
          (run_ok runtime (Signal.Observer.read observer))
  in
  set 1;
  set 2;
  set 3;
  check "before initial stabilize";
  stabilize_model ();
  run_ok runtime Signal.stabilize;
  check "initial stabilize";
  set 4;
  set 5;
  set 6;
  stabilize_model ();
  run_ok runtime Signal.stabilize;
  check "second stabilize";
  run_ok runtime (Signal.Observer.dispose observer)

type cutoff_op =
  | Cutoff_set of int
  | Cutoff_stabilize
  | Cutoff_read

let pp_cutoff_op formatter = function
  | Cutoff_set value -> Format.fprintf formatter "Set %d" value
  | Cutoff_stabilize -> Format.pp_print_string formatter "Stabilize"
  | Cutoff_read -> Format.pp_print_string formatter "Read"

let generate_cutoff_trace ~seed ~steps =
  let random = Random.State.make [| seed; steps; 101 |] in
  let next_value () = Random.State.int random 9 in
  let next_op index =
    if index mod 5 = 0 then Cutoff_stabilize
    else
      match Random.State.int random 10 with
      | 0 | 1 | 2 | 3 | 4 -> Cutoff_set (next_value ())
      | 5 | 6 -> Cutoff_read
      | _ -> Cutoff_stabilize
  in
  let rec loop index acc =
    if index = steps then List.rev (Cutoff_stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  Cutoff_stabilize :: loop 1 []

let publish_int current updates next =
  let update =
    match !current with
    | None -> Some (Initialized next)
    | Some current ->
        if current = next then None else Some (Changed (current, next))
  in
  current := Some next;
  Option.iter (fun update -> updates := update :: !updates) update

let check_int_updates label expected actual =
  Alcotest.(check (list observed_update))
    (label ^ " updates") (List.rev !expected) (List.rev !actual)

type effectful_update_op =
  | Effectful_set_left of int
  | Effectful_set_right of int
  | Effectful_update_left of int
  | Effectful_update_right of int
  | Effectful_update_left_and_right of int * int
  | Effectful_fail_left
  | Effectful_defect_right
  | Effectful_stabilize
  | Effectful_read

let pp_effectful_update_op formatter = function
  | Effectful_set_left value -> Format.fprintf formatter "Set_left %d" value
  | Effectful_set_right value -> Format.fprintf formatter "Set_right %d" value
  | Effectful_update_left delta ->
      Format.fprintf formatter "Update_left %+d" delta
  | Effectful_update_right delta ->
      Format.fprintf formatter "Update_right %+d" delta
  | Effectful_update_left_and_right (left_delta, right_delta) ->
      Format.fprintf formatter "Update_left_and_right { left = %+d; right = %+d }"
        left_delta right_delta
  | Effectful_fail_left -> Format.pp_print_string formatter "Fail_left"
  | Effectful_defect_right -> Format.pp_print_string formatter "Defect_right"
  | Effectful_stabilize -> Format.pp_print_string formatter "Stabilize"
  | Effectful_read -> Format.pp_print_string formatter "Read"

let generate_effectful_update_trace ~seed ~steps =
  let random = Random.State.make [| seed; steps; 131 |] in
  let next_value () = Random.State.int random 21 - 10 in
  let next_delta () = Random.State.int random 7 - 3 in
  let scripted =
    [
      Effectful_read;
      Effectful_stabilize;
      Effectful_set_left 2;
      Effectful_update_left 1;
      Effectful_read;
      Effectful_stabilize;
      Effectful_update_left_and_right (1, 5);
      Effectful_read;
      Effectful_stabilize;
      Effectful_fail_left;
      Effectful_defect_right;
      Effectful_stabilize;
    ]
  in
  let next_op index =
    if index mod 6 = 0 then Effectful_stabilize
    else
      match Random.State.int random 14 with
      | 0 | 1 -> Effectful_set_left (next_value ())
      | 2 | 3 -> Effectful_set_right (next_value ())
      | 4 | 5 | 6 -> Effectful_update_left (next_delta ())
      | 7 | 8 | 9 -> Effectful_update_right (next_delta ())
      | 10 -> Effectful_update_left_and_right (next_delta (), next_delta ())
      | 11 -> Effectful_fail_left
      | 12 -> Effectful_defect_right
      | _ -> Effectful_read
  in
  let rec loop index acc =
    if index = steps then List.rev (Effectful_stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  scripted @ loop 0 []

let test_effectful_update_trace_matches_model () =
  let run_trace name ops =
    Eta_test.with_test_clock @@ fun _sw _clock runtime ->
    let left = Signal.Var.create 1 in
    let right = Signal.Var.create 10 in
    let combined =
      Signal.map2 ( + ) (Signal.Var.watch left) (Signal.Var.watch right)
    in
    let actual_updates = ref [] in
    let observer =
      run_ok runtime
        (Signal.Observer.observe combined (fun update ->
             E.sync (fun () ->
                 actual_updates :=
                   observed_of_signal_update update :: !actual_updates)))
    in
    let pending_left = ref 1 in
    let pending_right = ref 10 in
    let current = ref None in
    let model_updates = ref [] in
    let check_sources label =
      Alcotest.(check int) (label ^ " left source") !pending_left
        (Signal.Var.value left);
      Alcotest.(check int) (label ^ " right source") !pending_right
        (Signal.Var.value right)
    in
    let check_read label =
      match !current with
      | None ->
          expect_uninitialized_observer label runtime
            (Signal.Observer.read observer)
      | Some expected ->
          Alcotest.(check int) label expected
            (run_ok runtime (Signal.Observer.read observer))
    in
    let set var pending value =
      pending := value;
      run_ok runtime (Signal.Var.set var value)
    in
    let update label var pending delta =
      let before = !pending in
      let seen = ref None in
      let expected = before + delta in
      let actual =
        run_ok runtime
          (Signal.Var.update_effect var (fun current ->
               E.sync (fun () -> seen := Some current)
               |> E.map (fun () -> current + delta)))
      in
      Alcotest.(check (option int))
        (label ^ " callback sees pending value")
        (Some before) !seen;
      Alcotest.(check int) (label ^ " update result") expected actual;
      pending := expected
    in
    let update_left_and_right left_delta right_delta =
      let before_left = !pending_left in
      let before_right = !pending_right in
      let seen_left = ref None in
      let seen_right = ref None in
      let expected_left = before_left + left_delta in
      let expected_right = before_right + right_delta in
      let actual =
        run_ok runtime
          (Signal.Var.update_effect left (fun current_left ->
               E.sync (fun () -> seen_left := Some current_left)
               |> E.bind (fun () ->
                      Signal.Var.update_effect right (fun current_right ->
                          E.sync (fun () -> seen_right := Some current_right)
                          |> E.map (fun () -> current_right + right_delta)))
               |> E.map (fun _ -> current_left + left_delta)))
      in
      Alcotest.(check (option int)) "left nested callback sees pending value"
        (Some before_left) !seen_left;
      Alcotest.(check (option int)) "right nested callback sees pending value"
        (Some before_right) !seen_right;
      Alcotest.(check int) "nested left update result" expected_left actual;
      pending_left := expected_left;
      pending_right := expected_right
    in
    let fail_left_then_update () =
      let before = !pending_left in
      expect_update_failed "typed update failure" runtime
        (Signal.Var.update_effect left (fun _ -> E.fail `Update_failed));
      Alcotest.(check int) "typed failure preserves left" before
        (Signal.Var.value left);
      update "left after failure" left pending_left 1
    in
    let defect_right_then_update () =
      let before = !pending_right in
      expect_die "update callback defect" runtime
        (Signal.Var.update_effect right (fun _ -> failwith "update defect"));
      Alcotest.(check int) "defect preserves right" before
        (Signal.Var.value right);
      update "right after defect" right pending_right 1
    in
    let stabilize label =
      publish_int current model_updates (!pending_left + !pending_right);
      run_ok runtime Signal.stabilize;
      check_int_updates label model_updates actual_updates;
      check_read (label ^ " read")
    in
    List.iteri
      (fun index op ->
        let label =
          Format.asprintf "%s step %d %a" name index
            pp_effectful_update_op op
        in
        (match op with
        | Effectful_set_left value -> set left pending_left value
        | Effectful_set_right value -> set right pending_right value
        | Effectful_update_left delta ->
            update "left" left pending_left delta
        | Effectful_update_right delta ->
            update "right" right pending_right delta
        | Effectful_update_left_and_right (left_delta, right_delta) ->
            update_left_and_right left_delta right_delta
        | Effectful_fail_left -> fail_left_then_update ()
        | Effectful_defect_right -> defect_right_then_update ()
        | Effectful_stabilize -> stabilize label
        | Effectful_read -> check_read label);
        check_sources label)
      ops;
    run_ok runtime (Signal.Observer.dispose observer)
  in
  List.iter
    (fun seed ->
      run_trace
        (Format.asprintf "effectful-update-seed-%d" seed)
        (generate_effectful_update_trace ~seed ~steps:75))
    [ 13; 29; 61; 113 ]

let int_list_equal = List.equal Int.equal
let cutoff_payload value = [ value mod 2 ]
let cutoff_payload_value payload = List.fold_left ( + ) 0 payload

let test_source_equality_trace_matches_model () =
  let parity_equal left right = left mod 2 = right mod 2 in
  let run_trace name ops =
    Eta_test.with_test_clock @@ fun _sw _clock runtime ->
    let source = Signal.Var.create ~equal:parity_equal 0 in
    let updates = ref [] in
    let observer =
      run_ok runtime
        (Signal.Observer.observe (Signal.Var.watch source) (fun update ->
             E.sync (fun () ->
                 updates := observed_of_signal_update update :: !updates)))
    in
    let pending = ref 0 in
    let committed = ref 0 in
    let source_dirty = ref false in
    let current = ref None in
    let model_updates = ref [] in
    let set value =
      pending := value;
      source_dirty := not (parity_equal !committed value);
      run_ok runtime (Signal.Var.set source value);
      Alcotest.(check int) "source value updates immediately" !pending
        (Signal.Var.value source)
    in
    let stabilize () =
      if !source_dirty then (
        committed := !pending;
        source_dirty := false);
      publish_int current model_updates !committed;
      run_ok runtime Signal.stabilize
    in
    List.iteri
      (fun index op ->
        let label =
          Format.asprintf "%s step %d %a" name index pp_cutoff_op op
        in
        match op with
        | Cutoff_set value -> set value
        | Cutoff_stabilize ->
            stabilize ();
            check_int_updates label model_updates updates
        | Cutoff_read -> (
            match !current with
            | None ->
                expect_uninitialized_observer label runtime
                  (Signal.Observer.read observer)
            | Some expected ->
                Alcotest.(check int) label expected
                  (run_ok runtime (Signal.Observer.read observer))))
      ops;
    run_ok runtime (Signal.Observer.dispose observer)
  in
  List.iter
    (fun seed ->
      run_trace
        (Format.asprintf "source-cutoff-seed-%d" seed)
        (generate_cutoff_trace ~seed ~steps:70))
    [ 17; 41; 73; 109 ]

let test_derived_observer_and_bind_cutoff_trace_matches_model () =
  let run_trace name ops =
    Eta_test.with_test_clock @@ fun _sw _clock runtime ->
    let source = Signal.Var.create 0 in
    let source_signal = Signal.Var.watch source in
    let physical =
      Signal.map (fun value -> cutoff_payload value) source_signal
    in
    let structural =
      Signal.map ~equal:int_list_equal
        (fun value -> cutoff_payload value)
        source_signal
    in
    let structural_downstream_calls = ref 0 in
    let structural_downstream =
      Signal.map
        (fun payload ->
          incr structural_downstream_calls;
          cutoff_payload_value payload)
        structural
    in
    let bind_inner_calls = ref 0 in
    let bound =
      Signal.bind ~equal:int_list_equal (Signal.const ()) (fun () ->
          source_signal
          |> Signal.map (fun value ->
                 incr bind_inner_calls;
                 cutoff_payload value))
    in
    let physical_callbacks = ref 0 in
    let structural_callbacks = ref 0 in
    let structural_downstream_updates = ref [] in
    let bound_callbacks = ref 0 in
    let normal_updates = ref [] in
    let suppressed_callbacks = ref 0 in
    let count callback_count _update =
      E.sync (fun () -> incr callback_count)
    in
    let physical_observer =
      run_ok runtime (Signal.Observer.observe physical (count physical_callbacks))
    in
    let structural_observer =
      run_ok runtime
        (Signal.Observer.observe structural (count structural_callbacks))
    in
    let structural_downstream_observer =
      run_ok runtime
        (Signal.Observer.observe structural_downstream (fun update ->
             E.sync (fun () ->
                 structural_downstream_updates :=
                   observed_of_signal_update update
                   :: !structural_downstream_updates)))
    in
    let bound_observer =
      run_ok runtime (Signal.Observer.observe bound (count bound_callbacks))
    in
    let normal_observer =
      run_ok runtime
        (Signal.Observer.observe source_signal (fun update ->
             E.sync (fun () ->
                 normal_updates :=
                   observed_of_signal_update update :: !normal_updates)))
    in
    let suppressed_observer =
      run_ok runtime
        (Signal.Observer.observe ~equal:(fun _ _ -> true) source_signal
           (fun _update -> E.sync (fun () -> incr suppressed_callbacks)))
    in
    let pending = ref 0 in
    let committed = ref 0 in
    let source_dirty = ref true in
    let normal_current = ref None in
    let normal_model_updates = ref [] in
    let physical_model_callbacks = ref 0 in
    let structural_model_callbacks = ref 0 in
    let structural_current = ref None in
    let structural_downstream_model_calls = ref 0 in
    let structural_downstream_current = ref None in
    let structural_downstream_model_updates = ref [] in
    let bound_model_callbacks = ref 0 in
    let bound_model_inner_calls = ref 0 in
    let bound_current = ref None in
    let suppressed_model_callbacks = ref 0 in
    let set value =
      pending := value;
      source_dirty := !committed <> value;
      run_ok runtime (Signal.Var.set source value)
    in
    let maybe_publish_payload current callbacks next =
      match !current with
      | None ->
          current := Some next;
          incr callbacks;
          true
      | Some previous when int_list_equal previous next -> false
      | Some _ ->
          current := Some next;
          incr callbacks;
          true
    in
    let stabilize () =
      if !source_dirty then (
        committed := !pending;
        source_dirty := false;
        publish_int normal_current normal_model_updates !committed;
        incr physical_model_callbacks;
        let structural_next = cutoff_payload !committed in
        let structural_changed =
          maybe_publish_payload structural_current structural_model_callbacks
            structural_next
        in
        if structural_changed then (
          incr structural_downstream_model_calls;
          publish_int structural_downstream_current
            structural_downstream_model_updates
            (cutoff_payload_value structural_next));
        incr bound_model_inner_calls;
        ignore
          (maybe_publish_payload bound_current bound_model_callbacks
             (cutoff_payload !committed));
        if !suppressed_model_callbacks = 0 then
          incr suppressed_model_callbacks);
      run_ok runtime Signal.stabilize
    in
    let check label =
      check_int_updates label normal_model_updates normal_updates;
      Alcotest.(check int)
        (label ^ " physical callbacks") !physical_model_callbacks
        !physical_callbacks;
      Alcotest.(check int)
        (label ^ " structural callbacks") !structural_model_callbacks
        !structural_callbacks;
      check_int_updates
        (label ^ " structural downstream") structural_downstream_model_updates
        structural_downstream_updates;
      Alcotest.(check int)
        (label ^ " structural downstream recomputes")
        !structural_downstream_model_calls !structural_downstream_calls;
      Alcotest.(check int)
        (label ^ " bind callbacks") !bound_model_callbacks !bound_callbacks;
      Alcotest.(check int)
        (label ^ " bind inner calls") !bound_model_inner_calls
        !bind_inner_calls;
      Alcotest.(check int)
        (label ^ " suppressed callbacks") !suppressed_model_callbacks
        !suppressed_callbacks
    in
    let check_reads label =
      match !normal_current with
      | None ->
          expect_uninitialized_observer (label ^ " normal") runtime
            (Signal.Observer.read normal_observer)
      | Some expected ->
          Alcotest.(check int) (label ^ " normal") expected
            (run_ok runtime (Signal.Observer.read normal_observer));
          Alcotest.(check int) (label ^ " suppressed") expected
            (run_ok runtime (Signal.Observer.read suppressed_observer));
          Alcotest.(check (list int))
            (label ^ " physical") (cutoff_payload expected)
            (run_ok runtime (Signal.Observer.read physical_observer));
          Alcotest.(check (list int))
            (label ^ " structural")
            (Option.value ~default:(cutoff_payload expected) !structural_current)
            (run_ok runtime (Signal.Observer.read structural_observer));
          Alcotest.(check int)
            (label ^ " structural downstream")
            (cutoff_payload_value
               (Option.value ~default:(cutoff_payload expected)
                  !structural_current))
            (run_ok runtime
               (Signal.Observer.read structural_downstream_observer));
          Alcotest.(check (list int))
            (label ^ " bind")
            (Option.value ~default:(cutoff_payload expected) !bound_current)
            (run_ok runtime (Signal.Observer.read bound_observer))
    in
    List.iteri
      (fun index op ->
        let label =
          Format.asprintf "%s step %d %a" name index pp_cutoff_op op
        in
        match op with
        | Cutoff_set value -> set value
        | Cutoff_stabilize ->
            stabilize ();
            check label
        | Cutoff_read -> check_reads label)
      ops;
    run_ok runtime (Signal.Observer.dispose physical_observer);
    run_ok runtime (Signal.Observer.dispose structural_observer);
    run_ok runtime (Signal.Observer.dispose structural_downstream_observer);
    run_ok runtime (Signal.Observer.dispose bound_observer);
    run_ok runtime (Signal.Observer.dispose normal_observer);
    run_ok runtime (Signal.Observer.dispose suppressed_observer)
  in
  List.iter
    (fun seed ->
      run_trace
        (Format.asprintf "derived-cutoff-seed-%d" seed)
        (generate_cutoff_trace ~seed ~steps:80))
    [ 23; 59; 97; 131 ]

let test_observer_phase_mutation_matches_model () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 1 in
  let signal = Signal.Var.watch source in
  let actual_updates = ref [] in
  let callback update =
    let observed = observed_of_signal_update update in
    E.sync (fun () -> actual_updates := observed :: !actual_updates)
    |> E.bind (fun () ->
           match observed with
           | Initialized 1 ->
               Signal.Var.set source 2
               |> E.map_error (fun _ -> `Observer_failed)
           | Changed (_, 2) ->
               Signal.Var.set source 3
               |> E.map_error (fun _ -> `Observer_failed)
           | Initialized _ | Changed _ -> E.unit)
  in
  let observer = run_ok runtime (Signal.Observer.observe signal callback) in
  let model_pending = ref 1 in
  let model_current = ref None in
  let model_updates = ref [] in
  let stabilize_model () =
    let next = !model_pending in
    let update =
      match !model_current with
      | None -> Some (Initialized next)
      | Some current ->
          if current = next then None else Some (Changed (current, next))
    in
    model_current := Some next;
    match update with
    | None -> ()
    | Some update ->
        model_updates := update :: !model_updates;
        (match update with
         | Initialized 1 -> model_pending := 2
         | Changed (_, 2) -> model_pending := 3
         | Initialized _ | Changed _ -> ())
  in
  let check_step label =
    stabilize_model ();
    run_ok runtime Signal.stabilize;
    Alcotest.(check (list observed_update))
      (label ^ " updates") (List.rev !model_updates) (List.rev !actual_updates);
    match !model_current with
    | None -> ()
    | Some expected ->
        Alcotest.(check int) (label ^ " read") expected
          (run_ok runtime (Signal.Observer.read observer))
  in
  check_step "initial";
  check_step "observer mutation";
  check_step "second observer mutation";
  run_ok runtime (Signal.Observer.dispose observer)

let test_observer_failure_retry_matches_model () =
  let pp_delivery_op formatter = function
    | `Set value -> Format.fprintf formatter "Set %d" value
    | `Fail_next -> Format.pp_print_string formatter "Fail_next"
    | `Die_next -> Format.pp_print_string formatter "Die_next"
    | `Stabilize -> Format.pp_print_string formatter "Stabilize"
    | `Read -> Format.pp_print_string formatter "Read"
  in
  let generate_delivery_trace ~seed ~steps =
    let random = Random.State.make [| seed |] in
    let next_value () = Random.State.int random 3 in
    let next_op index =
      if index mod 5 = 0 then `Stabilize
      else
        match Random.State.int random 10 with
        | 0 | 1 | 2 | 3 -> `Set (next_value ())
        | 4 -> `Fail_next
        | 5 -> `Die_next
        | 6 | 7 -> `Read
        | _ -> `Stabilize
    in
    let rec loop index acc =
      if index = steps then List.rev (`Stabilize :: acc)
      else loop (index + 1) (next_op index :: acc)
    in
    `Stabilize :: loop 1 []
  in
  let run_delivery_trace name ops =
    Eta_test.with_test_clock @@ fun _sw _clock runtime ->
    let source = Signal.Var.create 0 in
    let signal = Signal.Var.watch source in
    let first_delivered_updates = ref [] in
    let second_delivered_updates = ref [] in
    let next_delivery_outcome = ref `Ok in
    let record updates update =
      E.sync (fun () ->
          updates := observed_of_signal_update update :: !updates)
    in
    let first_observer =
      run_ok runtime
        (Signal.Observer.observe signal (record first_delivered_updates))
    in
    let second_callback update =
      if !next_delivery_outcome = `Die then (
        next_delivery_outcome := `Ok;
        failwith "observer delivery defect");
      if !next_delivery_outcome = `Fail then (
        next_delivery_outcome := `Ok;
        E.fail `Observer_failed)
      else
        E.sync (fun () ->
            second_delivered_updates :=
              observed_of_signal_update update :: !second_delivered_updates)
    in
    let second_observer =
      run_ok runtime (Signal.Observer.observe signal second_callback)
    in
    let model_pending = ref 0 in
    let model_current = ref None in
    let model_next_outcome = ref `Ok in
    let delivery_base = function
      | `Never -> None
      | `Delivered value -> Some value
      | `Pending (Initialized _) -> None
      | `Pending (Changed (old_value, _)) -> Some old_value
    in
    let delivery_pending = function
      | `Pending _ -> true
      | `Never | `Delivered _ -> false
    in
    let delivered_value = function
      | Initialized value -> value
      | Changed (_, value) -> value
    in
    let deliver_slot delivery delivered_updates changed next outcome =
      let update =
        match delivery_base !delivery with
        | None -> Some (Initialized next)
        | Some base ->
            if changed || delivery_pending !delivery then
              if base = next then (
                delivery := `Delivered next;
                None)
              else Some (Changed (base, next))
            else None
      in
      match update with
      | None -> `Ok
      | Some update -> (
          delivery := `Pending update;
          match outcome with
          | `Ok ->
              delivered_updates := update :: !delivered_updates;
              delivery := `Delivered (delivered_value update);
              `Ok
          | `Fail -> `Observer_failed
          | `Die -> `Die)
    in
    let first_delivery =
      ref
        (`Never :
          [ `Delivered of int | `Never | `Pending of observed_update ])
    in
    let second_delivery =
      ref
        (`Never :
          [ `Delivered of int | `Never | `Pending of observed_update ])
    in
    let first_model_delivered = ref [] in
    let second_model_delivered = ref [] in
    let stabilize_model () =
      let next = !model_pending in
      let changed =
        match !model_current with
        | None -> true
        | Some current -> current <> next
      in
      model_current := Some next;
      match
        deliver_slot first_delivery first_model_delivered changed next `Ok
      with
      | `Observer_failed | `Die as unexpected -> unexpected
      | `Ok ->
          let outcome = !model_next_outcome in
          let result =
            deliver_slot second_delivery second_model_delivered changed next
              outcome
          in
          if result <> `Ok then model_next_outcome := `Ok;
          result
    in
    let check_delivered label =
      Alcotest.(check (list observed_update))
        (label ^ " first delivered") (List.rev !first_model_delivered)
        (List.rev !first_delivered_updates);
      Alcotest.(check (list observed_update))
        (label ^ " second delivered") (List.rev !second_model_delivered)
        (List.rev !second_delivered_updates)
    in
    let check_read label =
      match !model_current with
      | None -> ()
      | Some expected ->
          Alcotest.(check int) (label ^ " first read") expected
            (run_ok runtime (Signal.Observer.read first_observer));
          Alcotest.(check int) (label ^ " second read") expected
            (run_ok runtime (Signal.Observer.read second_observer))
    in
    List.iteri
      (fun index op ->
        let label =
          Format.asprintf "%s step %d %a" name index pp_delivery_op op
        in
        match op with
        | `Set value ->
            model_pending := value;
            run_ok runtime (Signal.Var.set source value)
        | `Fail_next ->
            model_next_outcome := `Fail;
            next_delivery_outcome := `Fail
        | `Die_next ->
            model_next_outcome := `Die;
            next_delivery_outcome := `Die
        | `Read -> check_read label
        | `Stabilize -> (
            match stabilize_model () with
            | `Ok ->
                run_ok runtime Signal.stabilize;
                check_delivered label;
                check_read label
            | `Observer_failed ->
                expect_observer_failed label runtime Signal.stabilize;
                check_delivered label;
                check_read label
            | `Die ->
                expect_die label runtime Signal.stabilize;
                check_delivered label;
                check_read label))
      ops;
    run_ok runtime (Signal.Observer.dispose first_observer);
    run_ok runtime (Signal.Observer.dispose second_observer)
  in
  let scripted =
    [
      `Stabilize;
      `Fail_next;
      `Set 1;
      `Stabilize;
      `Set 0;
      `Stabilize;
      `Stabilize;
      `Die_next;
      `Set 2;
      `Stabilize;
      `Stabilize;
      `Set 1;
      `Stabilize;
    ]
  in
  run_delivery_trace "observer-failure-scripted" scripted;
  List.iter
    (fun seed ->
      run_delivery_trace
        (Format.asprintf "observer-failure-seed-%d" seed)
        (generate_delivery_trace ~seed ~steps:48))
    [ 11; 23; 37; 41; 53 ]

type pure_failure_op =
  | Pure_set of int
  | Pure_stabilize
  | Pure_read

let pp_pure_failure_op formatter = function
  | Pure_set value -> Format.fprintf formatter "Set %d" value
  | Pure_stabilize -> Format.pp_print_string formatter "Stabilize"
  | Pure_read -> Format.pp_print_string formatter "Read"

let generate_pure_failure_trace ~seed ~steps =
  let random = Random.State.make [| seed; steps; 2 |] in
  let next_value () =
    match Random.State.int random 6 with
    | 0 | 1 -> 2
    | 2 -> -1
    | 3 -> 0
    | 4 -> 1
    | _ -> 3
  in
  let next_op index =
    if index mod 5 = 0 then Pure_stabilize
    else
      match Random.State.int random 10 with
      | 0 | 1 | 2 | 3 | 4 -> Pure_set (next_value ())
      | 5 -> Pure_read
      | _ -> Pure_stabilize
  in
  let rec loop index acc =
    if index = steps then
      List.rev (Pure_stabilize :: Pure_set 3 :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  Pure_stabilize :: loop 1 []

let run_pure_failure_trace name ops =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 1 in
  let signal =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           if value = 2 then failwith "model pure failure";
           value)
  in
  let actual_updates = ref [] in
  let record update =
    E.sync (fun () ->
        actual_updates := observed_of_signal_update update :: !actual_updates)
  in
  let observer = run_ok runtime (Signal.Observer.observe signal record) in
  let model_pending = ref 1 in
  let model_current = ref None in
  let model_updates = ref [] in
  let stabilize_model () =
    if !model_pending = 2 then `Pure_failure
    else
      let value = !model_pending in
      let update =
        match !model_current with
        | None -> Some (Initialized value)
        | Some current ->
            if current = value then None else Some (Changed (current, value))
      in
      model_current := Some value;
      Option.iter
        (fun update -> model_updates := update :: !model_updates)
        update;
      `Committed
  in
  let check_model label =
    Alcotest.(check (list observed_update))
      (label ^ " updates") (List.rev !model_updates) (List.rev !actual_updates);
    match !model_current with
    | None ->
        expect_uninitialized_observer label runtime
          (Signal.Observer.read observer)
    | Some expected ->
        Alcotest.(check int) (label ^ " read") expected
          (run_ok runtime (Signal.Observer.read observer))
  in
  List.iteri
    (fun index op ->
      let label =
        Format.asprintf "%s step %d %a" name index pp_pure_failure_op op
      in
      (match op with
      | Pure_set value ->
          model_pending := value;
          run_ok runtime (Signal.Var.set source value)
      | Pure_stabilize -> (
          match stabilize_model () with
          | `Committed -> run_ok runtime Signal.stabilize
          | `Pure_failure -> expect_die label runtime Signal.stabilize)
      | Pure_read -> ());
      check_model label)
    ops;
  run_ok runtime (Signal.Observer.dispose observer)

let test_pure_failure_matches_model () =
  run_pure_failure_trace "pure-failure-scripted"
    [
      Pure_stabilize;
      Pure_read;
      Pure_set 2;
      Pure_stabilize;
      Pure_read;
      Pure_stabilize;
      Pure_set 3;
      Pure_stabilize;
      Pure_read;
    ];
  List.iter
    (fun seed ->
      run_pure_failure_trace
        (Format.asprintf "pure-failure-seed-%d" seed)
        (generate_pure_failure_trace ~seed ~steps:48))
    [ 5; 17; 29; 41; 61 ]

let test_dynamic_cycle_preserves_snapshot_matches_model () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let a_target = Signal.Var.create (Signal.const 1) in
  let b_target = Signal.Var.create (Signal.const 10) in
  let a = Signal.bind (Signal.Var.watch a_target) (fun signal -> signal) in
  let b = Signal.bind (Signal.Var.watch b_target) (fun signal -> signal) in
  let a_updates = ref [] in
  let b_updates = ref [] in
  let record updates update =
    E.sync (fun () ->
        updates := observed_of_signal_update update :: !updates)
  in
  let a_observer =
    run_ok runtime (Signal.Observer.observe a (record a_updates))
  in
  let b_observer =
    run_ok runtime (Signal.Observer.observe b (record b_updates))
  in
  let model_a = ref None in
  let model_b = ref None in
  let model_a_updates = ref [] in
  let model_b_updates = ref [] in
  let publish current updates next =
    let update =
      match !current with
      | None -> Some (Initialized next)
      | Some previous ->
          if previous = next then None else Some (Changed (previous, next))
    in
    current := Some next;
    Option.iter (fun update -> updates := update :: !updates) update
  in
  let commit_model ~a_value ~b_value =
    publish model_a model_a_updates a_value;
    publish model_b model_b_updates b_value
  in
  let check label =
    Alcotest.(check (list observed_update))
      (label ^ " a updates") (List.rev !model_a_updates)
      (List.rev !a_updates);
    Alcotest.(check (list observed_update))
      (label ^ " b updates") (List.rev !model_b_updates)
      (List.rev !b_updates);
    Option.iter
      (fun expected ->
        Alcotest.(check int) (label ^ " a read") expected
          (run_ok runtime (Signal.Observer.read a_observer)))
      !model_a;
    Option.iter
      (fun expected ->
        Alcotest.(check int) (label ^ " b read") expected
          (run_ok runtime (Signal.Observer.read b_observer)))
      !model_b
  in
  commit_model ~a_value:1 ~b_value:10;
  run_ok runtime Signal.stabilize;
  check "initial";
  run_ok runtime (Signal.Var.set a_target b);
  commit_model ~a_value:10 ~b_value:10;
  run_ok runtime Signal.stabilize;
  check "one way";
  run_ok runtime (Signal.Var.set a_target (Signal.const 2));
  run_ok runtime (Signal.Var.set b_target a);
  commit_model ~a_value:2 ~b_value:2;
  run_ok runtime Signal.stabilize;
  check "reverse";
  run_ok runtime (Signal.Var.set a_target b);
  run_ok runtime (Signal.Var.set b_target a);
  expect_graph_error "cycle" (( = ) `Cycle) runtime Signal.stabilize;
  check "after cycle";
  run_ok runtime (Signal.Var.set a_target (Signal.const 3));
  run_ok runtime (Signal.Var.set b_target (Signal.const 4));
  commit_model ~a_value:3 ~b_value:4;
  run_ok runtime Signal.stabilize;
  check "after recovery";
  run_ok runtime (Signal.Observer.dispose a_observer);
  run_ok runtime (Signal.Observer.dispose b_observer)

let test_dispose_demand_matches_model () =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 0 in
  let recomputes = ref 0 in
  let signal =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           incr recomputes;
           value)
  in
  let first_updates = ref [] in
  let second_updates = ref [] in
  let record updates update =
    E.sync (fun () ->
        updates := observed_of_signal_update update :: !updates)
  in
  let preinit_updates = ref [] in
  let model_pending = ref 0 in
  let model_recomputes = ref 0 in
  let preinit_model_current = ref None in
  let preinit_model_updates = ref [] in
  let first_model_current = ref None in
  let second_model_current = ref None in
  let first_model_updates = ref [] in
  let second_model_updates = ref [] in
  let stabilize_model ~demanded observer_current updates =
    if demanded then (
      incr model_recomputes;
      let value = !model_pending in
      let update =
        match !observer_current with
        | None -> Some (Initialized value)
        | Some current ->
            if current = value then None else Some (Changed (current, value))
      in
      observer_current := Some value;
      Option.iter (fun update -> updates := update :: !updates) update)
  in
  let check_updates label model actual =
    Alcotest.(check (list observed_update))
      label (List.rev !model) (List.rev !actual)
  in
  let preinit_observer =
    run_ok runtime (Signal.Observer.observe signal (record preinit_updates))
  in
  run_ok runtime (Signal.Observer.dispose preinit_observer);
  model_pending := 1;
  run_ok runtime (Signal.Var.set source 1);
  stabilize_model ~demanded:false preinit_model_current preinit_model_updates;
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "disposed uninitialized demand does not recompute"
    !model_recomputes !recomputes;
  check_updates "disposed uninitialized observer receives no update"
    preinit_model_updates preinit_updates;
  expect_disposed_observer "disposed uninitialized read" runtime
    (Signal.Observer.read preinit_observer);
  let first_observer =
    run_ok runtime (Signal.Observer.observe signal (record first_updates))
  in
  stabilize_model ~demanded:true first_model_current first_model_updates;
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "initial recompute" !model_recomputes !recomputes;
  check_updates "first observer initialized" first_model_updates first_updates;
  Alcotest.(check int) "first read" 1
    (run_ok runtime (Signal.Observer.read first_observer));
  run_ok runtime (Signal.Observer.dispose first_observer);
  expect_disposed_observer "disposed initialized read" runtime
    (Signal.Observer.read first_observer);
  model_pending := 2;
  run_ok runtime (Signal.Var.set source 2);
  stabilize_model ~demanded:false first_model_current first_model_updates;
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "disposed demand does not recompute" !model_recomputes
    !recomputes;
  check_updates "disposed observer receives no update" first_model_updates
    first_updates;
  let second_observer =
    run_ok runtime (Signal.Observer.observe signal (record second_updates))
  in
  stabilize_model ~demanded:true second_model_current second_model_updates;
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "reobserve recomputes latest pending value"
    !model_recomputes !recomputes;
  check_updates "second observer initialized with latest value"
    second_model_updates second_updates;
  Alcotest.(check int) "second read" 2
    (run_ok runtime (Signal.Observer.read second_observer));
  run_ok runtime (Signal.Observer.dispose second_observer)

type observer_slot =
  | First_observer
  | Second_observer

type lifecycle_op =
  | Lifecycle_set of int
  | Lifecycle_observe of observer_slot
  | Lifecycle_dispose of observer_slot
  | Lifecycle_stabilize
  | Lifecycle_read of observer_slot

type lifecycle_slot = {
  mutable actual_observer : int Signal.Observer.t option;
  mutable actual_updates : observed_update list;
  mutable model_active : bool;
  mutable model_current : int option;
  mutable model_updates : observed_update list;
}

let pp_observer_slot formatter = function
  | First_observer -> Format.pp_print_string formatter "first"
  | Second_observer -> Format.pp_print_string formatter "second"

let pp_lifecycle_op formatter = function
  | Lifecycle_set value -> Format.fprintf formatter "Set %d" value
  | Lifecycle_observe slot ->
      Format.fprintf formatter "Observe %a" pp_observer_slot slot
  | Lifecycle_dispose slot ->
      Format.fprintf formatter "Dispose %a" pp_observer_slot slot
  | Lifecycle_stabilize -> Format.pp_print_string formatter "Stabilize"
  | Lifecycle_read slot ->
      Format.fprintf formatter "Read %a" pp_observer_slot slot

let create_lifecycle_slot () =
  {
    actual_observer = None;
    actual_updates = [];
    model_active = false;
    model_current = None;
    model_updates = [];
  }

let lifecycle_slot first second = function
  | First_observer -> first
  | Second_observer -> second

let lifecycle_observer_slots first second = [ first; second ]

let lifecycle_signal_value source_value = source_value * 2

let lifecycle_record slot update =
  E.sync (fun () ->
      slot.actual_updates <-
        observed_of_signal_update update :: slot.actual_updates)

let lifecycle_observe runtime signal slot =
  match slot.actual_observer with
  | Some _ -> ()
  | None ->
      let observer =
        run_ok runtime
          (Signal.Observer.observe signal (lifecycle_record slot))
      in
      slot.actual_observer <- Some observer;
      slot.model_active <- true;
      slot.model_current <- None

let lifecycle_dispose runtime slot =
  match slot.actual_observer with
  | None -> ()
  | Some observer ->
      run_ok runtime (Signal.Observer.dispose observer);
      slot.actual_observer <- None;
      slot.model_active <- false;
      slot.model_current <- None

let lifecycle_model_stabilize pending slots =
  let next = lifecycle_signal_value !pending in
  List.iter
    (fun slot ->
      if slot.model_active then (
        let update =
          match slot.model_current with
          | None -> Some (Initialized next)
          | Some current ->
              if current = next then None else Some (Changed (current, next))
        in
        slot.model_current <- Some next;
        Option.iter
          (fun update -> slot.model_updates <- update :: slot.model_updates)
          update))
    slots

let lifecycle_check_slot label slot =
  Alcotest.(check (list observed_update))
    (label ^ " updates") (List.rev slot.model_updates)
    (List.rev slot.actual_updates)

let lifecycle_read label runtime slot =
  match slot.actual_observer with
  | None -> ()
  | Some observer -> (
      match slot.model_current with
      | None ->
          expect_uninitialized_observer label runtime
            (Signal.Observer.read observer)
      | Some expected ->
          Alcotest.(check int) label expected
            (run_ok runtime (Signal.Observer.read observer)))

let generate_lifecycle_trace ~seed ~steps =
  let random = Random.State.make [| seed |] in
  let next_slot () =
    if Random.State.bool random then First_observer else Second_observer
  in
  let next_value () = Random.State.int random 11 - 5 in
  let next_op index =
    if index mod 8 = 0 then Lifecycle_stabilize
    else
      match Random.State.int random 12 with
      | 0 | 1 | 2 -> Lifecycle_set (next_value ())
      | 3 | 4 -> Lifecycle_observe (next_slot ())
      | 5 | 6 -> Lifecycle_dispose (next_slot ())
      | 7 | 8 -> Lifecycle_read (next_slot ())
      | _ -> Lifecycle_stabilize
  in
  let rec loop index acc =
    if index = steps then List.rev (Lifecycle_stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  [
    Lifecycle_observe First_observer;
    Lifecycle_read First_observer;
    Lifecycle_set 1;
    Lifecycle_stabilize;
  ]
  @ loop 1 []

let run_lifecycle_trace name ops =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 0 in
  let signal = Signal.Var.watch source |> Signal.map lifecycle_signal_value in
  let pending = ref 0 in
  let first = create_lifecycle_slot () in
  let second = create_lifecycle_slot () in
  let slots = lifecycle_observer_slots first second in
  List.iteri
    (fun index op ->
      let label =
        Format.asprintf "%s step %d %a" name index pp_lifecycle_op op
      in
      match op with
      | Lifecycle_set value ->
          pending := value;
          run_ok runtime (Signal.Var.set source value)
      | Lifecycle_observe slot ->
          lifecycle_observe runtime signal (lifecycle_slot first second slot)
      | Lifecycle_dispose slot ->
          lifecycle_dispose runtime (lifecycle_slot first second slot)
      | Lifecycle_stabilize ->
          lifecycle_model_stabilize pending slots;
          run_ok runtime Signal.stabilize;
          List.iter (lifecycle_check_slot label) slots
      | Lifecycle_read slot ->
          lifecycle_read label runtime (lifecycle_slot first second slot))
    ops;
  List.iter (lifecycle_dispose runtime) slots

let test_observer_lifecycle_trace_matches_model () =
  List.iter
    (fun seed ->
      run_lifecycle_trace
        (Format.asprintf "observer-lifecycle-seed-%d" seed)
        (generate_lifecycle_trace ~seed ~steps:90))
    [ 3; 17; 41; 79 ]

type branch_demand_op =
  | Branch_set_a of int
  | Branch_set_b of int
  | Branch_choose_a of bool
  | Branch_stabilize
  | Branch_read

type branch_model = {
  mutable branch_source : int;
  mutable branch_committed : int;
  mutable branch_current : int option;
  mutable branch_recomputes : int;
}

type bind_demand_model = {
  branch_a : branch_model;
  branch_b : branch_model;
  mutable pending_choose_a : bool;
  mutable committed_choose_a : bool;
  mutable bind_observer_current : int option;
  mutable bind_observed_updates : observed_update list;
}

let pp_branch_demand_op formatter = function
  | Branch_set_a value -> Format.fprintf formatter "Set_a %d" value
  | Branch_set_b value -> Format.fprintf formatter "Set_b %d" value
  | Branch_choose_a value -> Format.fprintf formatter "Choose_a %b" value
  | Branch_stabilize -> Format.pp_print_string formatter "Stabilize"
  | Branch_read -> Format.pp_print_string formatter "Read"

let create_branch_model value =
  {
    branch_source = value;
    branch_committed = value;
    branch_current = None;
    branch_recomputes = 0;
  }

let create_bind_demand_model () =
  {
    branch_a = create_branch_model 0;
    branch_b = create_branch_model 10;
    pending_choose_a = true;
    committed_choose_a = true;
    bind_observer_current = None;
    bind_observed_updates = [];
  }

let set_branch_model_source branch value =
  if branch.branch_source <> value then branch.branch_source <- value

let commit_branch_source branch =
  branch.branch_committed <- branch.branch_source

let selected_branch_model model =
  if model.committed_choose_a then model.branch_a else model.branch_b

let compute_branch_if_needed branch =
  match branch.branch_current with
  | Some value when value = branch.branch_committed -> value
  | None | Some _ ->
      branch.branch_recomputes <- branch.branch_recomputes + 1;
      branch.branch_current <- Some branch.branch_committed;
      branch.branch_committed

let stabilize_bind_demand_model model =
  commit_branch_source model.branch_a;
  commit_branch_source model.branch_b;
  let previous_choose_a = model.committed_choose_a in
  model.committed_choose_a <- model.pending_choose_a;
  let selected = selected_branch_model model in
  if previous_choose_a <> model.committed_choose_a then
    selected.branch_current <- None;
  let value = compute_branch_if_needed selected in
  let update =
    match model.bind_observer_current with
    | None -> Some (Initialized value)
    | Some current ->
        if current = value then None else Some (Changed (current, value))
  in
  model.bind_observer_current <- Some value;
  Option.iter
    (fun update ->
      model.bind_observed_updates <- update :: model.bind_observed_updates)
    update

let check_bind_demand_model label model updates recomputes_a recomputes_b =
  Alcotest.(check (list observed_update))
    (label ^ " updates") (List.rev model.bind_observed_updates)
    (List.rev !updates);
  Alcotest.(check int)
    (label ^ " branch a recomputes")
    model.branch_a.branch_recomputes !recomputes_a;
  Alcotest.(check int)
    (label ^ " branch b recomputes")
    model.branch_b.branch_recomputes !recomputes_b

let generate_branch_demand_trace ~seed ~steps =
  let random = Random.State.make [| seed |] in
  let next_value () = Random.State.int random 11 - 5 in
  let next_op index =
    if index mod 6 = 0 then Branch_stabilize
    else
      match Random.State.int random 12 with
      | 0 | 1 | 2 -> Branch_set_a (next_value ())
      | 3 | 4 | 5 -> Branch_set_b (next_value ())
      | 6 | 7 -> Branch_choose_a (Random.State.bool random)
      | 8 -> Branch_read
      | _ -> Branch_stabilize
  in
  let rec loop index acc =
    if index = steps then List.rev (Branch_stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  Branch_stabilize :: Branch_read :: loop 1 []

let run_bind_branch_demand_trace name ops =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let base_stats = run_ok runtime (Signal.stats ()) in
  let source_a = Signal.Var.create 0 in
  let source_b = Signal.Var.create 10 in
  let choose_a = Signal.Var.create true in
  let recomputes_a = ref 0 in
  let recomputes_b = ref 0 in
  let branch_signal source recomputes =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           incr recomputes;
           value)
  in
  let selected =
    Signal.bind (Signal.Var.watch choose_a) (fun use_a ->
        if use_a then branch_signal source_a recomputes_a
        else branch_signal source_b recomputes_b)
  in
  let branch_total_nodes = Array.make 2 None in
  let check_stats label model =
    Gc.full_major ();
    let stats = run_ok runtime (Signal.stats ()) in
    Alcotest.(check int) (label ^ " active observers")
      (base_stats.Signal.active_observer_count + 1)
      stats.Signal.active_observer_count;
    Alcotest.(check int) (label ^ " invalid observers")
      base_stats.Signal.invalid_observer_count
      stats.Signal.invalid_observer_count;
    let branch_index = if model.committed_choose_a then 0 else 1 in
    match branch_total_nodes.(branch_index) with
    | None ->
        branch_total_nodes.(branch_index) <-
          Some stats.Signal.total_node_count
    | Some baseline ->
        Alcotest.(check bool)
          (label ^ " does not retain inactive branch nodes")
          true
          (stats.Signal.total_node_count <= baseline)
  in
  let updates = ref [] in
  let record update =
    E.sync (fun () ->
        updates := observed_of_signal_update update :: !updates)
  in
  let observer = run_ok runtime (Signal.Observer.observe selected record) in
  let model = create_bind_demand_model () in
  List.iteri
    (fun index op ->
      let label =
        Format.asprintf "%s step %d %a" name index pp_branch_demand_op op
      in
      match op with
      | Branch_set_a value ->
          set_branch_model_source model.branch_a value;
          run_ok runtime (Signal.Var.set source_a value)
      | Branch_set_b value ->
          set_branch_model_source model.branch_b value;
          run_ok runtime (Signal.Var.set source_b value)
      | Branch_choose_a value ->
          model.pending_choose_a <- value;
          run_ok runtime (Signal.Var.set choose_a value)
      | Branch_stabilize ->
          stabilize_bind_demand_model model;
          run_ok runtime Signal.stabilize;
          check_bind_demand_model label model updates recomputes_a recomputes_b;
          check_stats label model
      | Branch_read -> (
          match model.bind_observer_current with
          | None ->
              expect_uninitialized_observer label runtime
                (Signal.Observer.read observer)
          | Some expected ->
              Alcotest.(check int) label expected
                (run_ok runtime (Signal.Observer.read observer))))
    ops;
  run_ok runtime (Signal.Observer.dispose observer)

let test_bind_branch_demand_trace_matches_model () =
  List.iter
    (fun seed ->
      run_bind_branch_demand_trace
        (Format.asprintf "bind-demand-seed-%d" seed)
        (generate_branch_demand_trace ~seed ~steps:100))
    [ 5; 23; 61; 97 ]

type nested_bind_op =
  | Nested_set_a of int
  | Nested_set_b of int
  | Nested_set_c of int
  | Nested_choose of int
  | Nested_inner_choose of bool
  | Nested_external_offset of int
  | Nested_stabilize
  | Nested_read

type nested_bind_model = {
  mutable nested_pending_a : int;
  mutable nested_pending_b : int;
  mutable nested_pending_c : int;
  mutable nested_pending_choose : int;
  mutable nested_pending_inner_choose : bool;
  mutable nested_pending_external_offset : int;
  mutable nested_committed_a : int;
  mutable nested_committed_b : int;
  mutable nested_committed_c : int;
  mutable nested_committed_choose : int;
  mutable nested_committed_inner_choose : bool;
  mutable nested_committed_external_offset : int;
  mutable nested_current : int option;
  mutable nested_updates : observed_update list;
}

let pp_nested_bind_op formatter = function
  | Nested_set_a value -> Format.fprintf formatter "Set_a %d" value
  | Nested_set_b value -> Format.fprintf formatter "Set_b %d" value
  | Nested_set_c value -> Format.fprintf formatter "Set_c %d" value
  | Nested_choose value -> Format.fprintf formatter "Choose %d" value
  | Nested_inner_choose value ->
      Format.fprintf formatter "Inner_choose %b" value
  | Nested_external_offset value ->
      Format.fprintf formatter "External_offset %d" value
  | Nested_stabilize -> Format.pp_print_string formatter "Stabilize"
  | Nested_read -> Format.pp_print_string formatter "Read"

let create_nested_bind_model () =
  {
    nested_pending_a = 1;
    nested_pending_b = 10;
    nested_pending_c = 100;
    nested_pending_choose = 0;
    nested_pending_inner_choose = true;
    nested_pending_external_offset = 5;
    nested_committed_a = 1;
    nested_committed_b = 10;
    nested_committed_c = 100;
    nested_committed_choose = 0;
    nested_committed_inner_choose = true;
    nested_committed_external_offset = 5;
    nested_current = None;
    nested_updates = [];
  }

let nested_bind_value model =
  match model.nested_committed_choose with
  | 0 ->
      if model.nested_committed_inner_choose then
        model.nested_committed_a + 1
      else model.nested_committed_b + 2
  | 1 -> model.nested_committed_c * 3
  | _ -> model.nested_committed_a + model.nested_committed_external_offset

let stabilize_nested_bind_model model =
  model.nested_committed_a <- model.nested_pending_a;
  model.nested_committed_b <- model.nested_pending_b;
  model.nested_committed_c <- model.nested_pending_c;
  model.nested_committed_choose <- model.nested_pending_choose;
  model.nested_committed_inner_choose <- model.nested_pending_inner_choose;
  model.nested_committed_external_offset <-
    model.nested_pending_external_offset;
  let next = nested_bind_value model in
  let update =
    match model.nested_current with
    | None -> Some (Initialized next)
    | Some current ->
        if current = next then None else Some (Changed (current, next))
  in
  model.nested_current <- Some next;
  Option.iter
    (fun update ->
      model.nested_updates <- update :: model.nested_updates)
    update

let generate_nested_bind_trace ~seed ~steps =
  let random = Random.State.make [| seed; steps |] in
  let next_value () = Random.State.int random 31 - 15 in
  let next_op index =
    if index mod 6 = 0 then Nested_stabilize
    else
      match Random.State.int random 16 with
      | 0 | 1 -> Nested_set_a (next_value ())
      | 2 | 3 -> Nested_set_b (next_value ())
      | 4 | 5 -> Nested_set_c (next_value ())
      | 6 | 7 | 8 -> Nested_choose (Random.State.int random 3)
      | 9 | 10 -> Nested_inner_choose (Random.State.bool random)
      | 11 | 12 -> Nested_external_offset (next_value ())
      | 13 -> Nested_read
      | _ -> Nested_stabilize
  in
  let rec loop index acc =
    if index = steps then List.rev (Nested_stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  Nested_read :: Nested_stabilize :: loop 1 []

let run_nested_bind_trace name ops =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source_a = Signal.Var.create 1 in
  let source_b = Signal.Var.create 10 in
  let source_c = Signal.Var.create 100 in
  let choose = Signal.Var.create 0 in
  let inner_choose = Signal.Var.create true in
  let external_offset = Signal.Var.create 5 in
  let external_bind =
    Signal.bind (Signal.Var.watch external_offset) (fun offset ->
        Signal.Var.watch source_a
        |> Signal.map (fun value -> value + offset))
  in
  let selected =
    Signal.bind (Signal.Var.watch choose) (function
      | 0 ->
          Signal.bind (Signal.Var.watch inner_choose) (fun use_a ->
              if use_a then
                Signal.Var.watch source_a
                |> Signal.map (fun value -> value + 1)
              else
                Signal.Var.watch source_b
                |> Signal.map (fun value -> value + 2))
      | 1 ->
          Signal.Var.watch source_c
          |> Signal.map (fun value -> value * 3)
      | _ -> external_bind)
  in
  let updates = ref [] in
  let record update =
    E.sync (fun () ->
        updates := observed_of_signal_update update :: !updates)
  in
  let observer = run_ok runtime (Signal.Observer.observe selected record) in
  let model = create_nested_bind_model () in
  List.iteri
    (fun index op ->
      let label =
        Format.asprintf "%s step %d %a" name index pp_nested_bind_op op
      in
      match op with
      | Nested_set_a value ->
          model.nested_pending_a <- value;
          run_ok runtime (Signal.Var.set source_a value)
      | Nested_set_b value ->
          model.nested_pending_b <- value;
          run_ok runtime (Signal.Var.set source_b value)
      | Nested_set_c value ->
          model.nested_pending_c <- value;
          run_ok runtime (Signal.Var.set source_c value)
      | Nested_choose value ->
          model.nested_pending_choose <- value;
          run_ok runtime (Signal.Var.set choose value)
      | Nested_inner_choose value ->
          model.nested_pending_inner_choose <- value;
          run_ok runtime (Signal.Var.set inner_choose value)
      | Nested_external_offset value ->
          model.nested_pending_external_offset <- value;
          run_ok runtime (Signal.Var.set external_offset value)
      | Nested_stabilize ->
          stabilize_nested_bind_model model;
          run_ok runtime Signal.stabilize;
          Alcotest.(check (list observed_update))
            (label ^ " updates") (List.rev model.nested_updates)
            (List.rev !updates)
      | Nested_read -> (
          match model.nested_current with
          | None ->
              expect_uninitialized_observer label runtime
                (Signal.Observer.read observer)
          | Some expected ->
              Alcotest.(check int) label expected
                (run_ok runtime (Signal.Observer.read observer))))
    ops;
  run_ok runtime (Signal.Observer.dispose observer)

let test_nested_bind_churn_trace_matches_model () =
  List.iter
    (fun seed ->
      run_nested_bind_trace
        (Format.asprintf "nested-bind-seed-%d" seed)
        (generate_nested_bind_trace ~seed ~steps:120))
    [ 13; 31; 71; 113 ]

type retained_side =
  | Retained_left
  | Retained_right

type retained_branch_op =
  | Retained_set_left of int
  | Retained_set_right of int
  | Retained_choose_left of bool
  | Retained_stabilize

type retained_branch_slot = {
  retained_side : retained_side;
  retained_signal : int Signal.signal;
  mutable retained_valid : bool;
}

type retained_branch_model = {
  mutable retained_pending_left : int;
  mutable retained_pending_right : int;
  mutable retained_pending_choose_left : bool;
  mutable retained_committed_left : int;
  mutable retained_committed_right : int;
  mutable retained_active_side : retained_side option;
}

let pp_retained_side formatter = function
  | Retained_left -> Format.pp_print_string formatter "left"
  | Retained_right -> Format.pp_print_string formatter "right"

let pp_retained_branch_op formatter = function
  | Retained_set_left value -> Format.fprintf formatter "Set_left %d" value
  | Retained_set_right value -> Format.fprintf formatter "Set_right %d" value
  | Retained_choose_left value ->
      Format.fprintf formatter "Choose_left %b" value
  | Retained_stabilize -> Format.pp_print_string formatter "Stabilize"

let retained_side_of_bool choose_left =
  if choose_left then Retained_left else Retained_right

let retained_side_equal left right =
  match (left, right) with
  | Retained_left, Retained_left | Retained_right, Retained_right -> true
  | Retained_left, Retained_right | Retained_right, Retained_left -> false

let create_retained_branch_model () =
  {
    retained_pending_left = 10;
    retained_pending_right = 20;
    retained_pending_choose_left = true;
    retained_committed_left = 10;
    retained_committed_right = 20;
    retained_active_side = None;
  }

let retained_branch_value model = function
  | Retained_left -> model.retained_committed_left
  | Retained_right -> model.retained_committed_right

let stabilize_retained_branch_model model retained_slots =
  let next_side =
    retained_side_of_bool model.retained_pending_choose_left
  in
  let switched =
    match model.retained_active_side with
    | None -> true
    | Some side -> not (retained_side_equal side next_side)
  in
  if switched then
    List.iter (fun slot -> slot.retained_valid <- false) !retained_slots;
  model.retained_committed_left <- model.retained_pending_left;
  model.retained_committed_right <- model.retained_pending_right;
  model.retained_active_side <- Some next_side;
  switched

let generate_retained_branch_trace ~seed ~steps =
  let random = Random.State.make [| seed; 31 |] in
  let next_value () = Random.State.int random 31 - 15 in
  let next_op index =
    if index mod 6 = 0 then Retained_stabilize
    else
      match Random.State.int random 12 with
      | 0 | 1 -> Retained_set_left (next_value ())
      | 2 | 3 -> Retained_set_right (next_value ())
      | 4 | 5 | 6 -> Retained_choose_left (Random.State.bool random)
      | _ -> Retained_stabilize
  in
  let rec loop index acc =
    if index = steps then List.rev (Retained_stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  Retained_stabilize :: loop 1 []

let run_retained_branch_trace name ops =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let left = Signal.Var.create 10 in
  let right = Signal.Var.create 20 in
  let choose_left = Signal.Var.create true in
  let retained_slots = ref [] in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) (fun choose_left ->
        let side = retained_side_of_bool choose_left in
        let signal =
          match side with
          | Retained_left -> Signal.Var.watch left
          | Retained_right -> Signal.Var.watch right
        in
        retained_slots :=
          {
            retained_side = side;
            retained_signal = signal;
            retained_valid = true;
          }
          :: !retained_slots;
        signal)
  in
  let selected_observer =
    run_ok runtime
      (Signal.Observer.observe selected (fun _ -> E.unit))
  in
  let model = create_retained_branch_model () in
  let check_retained_slot label index slot =
    let slot_label =
      Format.asprintf "%s retained %d %a" label index pp_retained_side
        slot.retained_side
    in
    if slot.retained_valid then (
      let updates = ref [] in
      let observer =
        run_ok runtime
          (Signal.Observer.observe slot.retained_signal (fun update ->
               E.sync (fun () ->
                   updates :=
                     observed_of_signal_update update :: !updates)))
      in
      run_ok runtime Signal.stabilize;
      let expected = retained_branch_value model slot.retained_side in
      Alcotest.(check int) (slot_label ^ " read") expected
        (run_ok runtime (Signal.Observer.read observer));
      Alcotest.(check (list observed_update))
        (slot_label ^ " updates") [ Initialized expected ]
        (List.rev !updates);
      run_ok runtime (Signal.Observer.dispose observer))
    else
      expect_graph_error (slot_label ^ " stale observe")
        (( = ) `Invalid_scope) runtime
        (Signal.Observer.observe slot.retained_signal (fun _ -> E.unit))
  in
  let check_retained_branches label =
    List.iteri (check_retained_slot label) !retained_slots
  in
  List.iteri
    (fun index op ->
      let label =
        Format.asprintf "%s step %d %a" name index pp_retained_branch_op op
      in
      match op with
      | Retained_set_left value ->
          model.retained_pending_left <- value;
          run_ok runtime (Signal.Var.set left value)
      | Retained_set_right value ->
          model.retained_pending_right <- value;
          run_ok runtime (Signal.Var.set right value)
      | Retained_choose_left value ->
          model.retained_pending_choose_left <- value;
          run_ok runtime (Signal.Var.set choose_left value)
      | Retained_stabilize ->
          let before_retained_count = List.length !retained_slots in
          let switched =
            stabilize_retained_branch_model model retained_slots
          in
          run_ok runtime Signal.stabilize;
          let expected_retained_count =
            before_retained_count + if switched then 1 else 0
          in
          Alcotest.(check int)
            (label ^ " retained branch count") expected_retained_count
            (List.length !retained_slots);
          check_retained_branches label)
    ops;
  run_ok runtime (Signal.Observer.dispose selected_observer)

let test_retained_branch_trace_matches_model () =
  List.iter
    (fun seed ->
      run_retained_branch_trace
        (Format.asprintf "retained-branch-seed-%d" seed)
        (generate_retained_branch_trace ~seed ~steps:54))
    [ 2; 11; 29; 47 ]

type diamond_op =
  | Diamond_set of int
  | Diamond_stabilize
  | Diamond_read

type diamond_model = {
  mutable diamond_pending : int;
  mutable diamond_committed : int;
  mutable diamond_initialized : bool;
  mutable diamond_recomputes : int;
  mutable diamond_left : int option;
  mutable diamond_right : int option;
  mutable diamond_output : int option;
}

let pp_diamond_op formatter = function
  | Diamond_set value -> Format.fprintf formatter "Set %d" value
  | Diamond_stabilize -> Format.pp_print_string formatter "Stabilize"
  | Diamond_read -> Format.pp_print_string formatter "Read"

let create_diamond_model () =
  {
    diamond_pending = 0;
    diamond_committed = 0;
    diamond_initialized = false;
    diamond_recomputes = 0;
    diamond_left = None;
    diamond_right = None;
    diamond_output = None;
  }

let diamond_values source =
  let shared = source + 1 in
  let left = shared + 10 in
  let right = shared + 20 in
  (left, right, (left * 1_000) + right)

let stabilize_diamond_model model =
  if (not model.diamond_initialized)
     || model.diamond_pending <> model.diamond_committed
  then (
    model.diamond_committed <- model.diamond_pending;
    model.diamond_initialized <- true;
    model.diamond_recomputes <- model.diamond_recomputes + 1;
    let left, right, output = diamond_values model.diamond_committed in
    model.diamond_left <- Some left;
    model.diamond_right <- Some right;
    model.diamond_output <- Some output;
    Some (left, right, output))
  else None

let diamond_current model =
  match (model.diamond_left, model.diamond_right, model.diamond_output) with
  | Some left, Some right, Some output -> Some (left, right, output)
  | None, None, None -> None
  | Some _, _, _ | None, Some _, _ | None, None, Some _ ->
      Alcotest.fail "inconsistent diamond model state"

let diamond_snapshot_label label left right output =
  Format.asprintf "%s:%d:%d:%d" label left right output

let take count list =
  let rec loop count list acc =
    if count <= 0 then List.rev acc
    else
      match list with
      | [] -> List.rev acc
      | head :: rest -> loop (count - 1) rest (head :: acc)
  in
  loop count list []

let check_diamond_snapshot_batch label snapshots before expected =
  let after = List.length !snapshots in
  let added = after - before in
  match expected with
  | None ->
      Alcotest.(check int) (label ^ " callback count") 0 added
  | Some (left, right, output) ->
      Alcotest.(check int) (label ^ " callback count") 3 added;
      let actual = take added !snapshots |> List.sort String.compare in
      let expected =
        [
          diamond_snapshot_label "left" left right output;
          diamond_snapshot_label "output" left right output;
          diamond_snapshot_label "right" left right output;
        ]
        |> List.sort String.compare
      in
      Alcotest.(check (list string)) (label ^ " callback snapshots")
        expected actual

let generate_diamond_trace ~seed ~steps =
  let random = Random.State.make [| seed |] in
  let next_value () = Random.State.int random 11 - 5 in
  let next_op index =
    if index mod 5 = 0 then Diamond_stabilize
    else
      match Random.State.int random 8 with
      | 0 | 1 | 2 | 3 -> Diamond_set (next_value ())
      | 4 -> Diamond_read
      | _ -> Diamond_stabilize
  in
  let rec loop index acc =
    if index = steps then List.rev (Diamond_stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  Diamond_stabilize :: Diamond_read :: loop 1 []

let run_diamond_trace name ops =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 0 in
  let shared_recomputes = ref 0 in
  let shared =
    Signal.Var.watch source
    |> Signal.map (fun value ->
           incr shared_recomputes;
           value + 1)
  in
  let left = Signal.map (fun value -> value + 10) shared in
  let right = Signal.map (fun value -> value + 20) shared in
  let output =
    Signal.map2 (fun left right -> (left * 1_000) + right) left right
  in
  let left_observer = ref None in
  let right_observer = ref None in
  let output_observer = ref None in
  let callback_snapshots = ref [] in
  let observer ref_ =
    match !ref_ with
    | Some observer -> observer
    | None -> Alcotest.fail "observer callback ran before registration"
  in
  let read_callback_snapshot label _update =
    Signal.Observer.read (observer left_observer)
    |> E.map_error (fun _ -> `Observer_failed)
    |> E.bind (fun left_value ->
           Signal.Observer.read (observer right_observer)
           |> E.map_error (fun _ -> `Observer_failed)
           |> E.bind (fun right_value ->
                  Signal.Observer.read (observer output_observer)
                  |> E.map_error (fun _ -> `Observer_failed)
                  |> E.bind (fun output_value ->
                         E.sync (fun () ->
                             callback_snapshots :=
                               diamond_snapshot_label label left_value
                                 right_value output_value
                               :: !callback_snapshots))))
  in
  left_observer :=
    Some
      (run_ok runtime
         (Signal.Observer.observe left (read_callback_snapshot "left")));
  right_observer :=
    Some
      (run_ok runtime
         (Signal.Observer.observe right (read_callback_snapshot "right")));
  output_observer :=
    Some
      (run_ok runtime
         (Signal.Observer.observe output (read_callback_snapshot "output")));
  let model = create_diamond_model () in
  List.iteri
    (fun index op ->
      let label =
        Format.asprintf "%s step %d %a" name index pp_diamond_op op
      in
      match op with
      | Diamond_set value ->
          model.diamond_pending <- value;
          run_ok runtime (Signal.Var.set source value)
      | Diamond_stabilize ->
          let before_callbacks = List.length !callback_snapshots in
          let expected_callbacks = stabilize_diamond_model model in
          run_ok runtime Signal.stabilize;
          Alcotest.(check int)
            (label ^ " shared recomputes")
            model.diamond_recomputes !shared_recomputes;
          check_diamond_snapshot_batch label callback_snapshots
            before_callbacks expected_callbacks
      | Diamond_read -> (
          match diamond_current model with
          | None -> ()
          | Some (expected_left, expected_right, expected_output) ->
              Alcotest.(check int) (label ^ " left read") expected_left
                (run_ok runtime
                   (Signal.Observer.read (observer left_observer)));
              Alcotest.(check int) (label ^ " right read") expected_right
                (run_ok runtime
                   (Signal.Observer.read (observer right_observer)));
              Alcotest.(check int) (label ^ " output read") expected_output
                (run_ok runtime
                   (Signal.Observer.read (observer output_observer)))))
    ops;
  run_ok runtime (Signal.Observer.dispose (observer left_observer));
  run_ok runtime (Signal.Observer.dispose (observer right_observer));
  run_ok runtime (Signal.Observer.dispose (observer output_observer))

let test_diamond_trace_matches_model () =
  List.iter
    (fun seed ->
      run_diamond_trace
        (Format.asprintf "diamond-seed-%d" seed)
        (generate_diamond_trace ~seed ~steps:80))
    [ 7; 19; 43; 89 ]

type small_graph_node =
  | Small_var of int
  | Small_map of {
      child : int;
      scale : int;
      bias : int;
    }
  | Small_map2 of {
      left : int;
      right : int;
      left_scale : int;
      right_scale : int;
      bias : int;
    }
  | Small_all_sum of {
      children : int list;
      bias : int;
    }
  | Small_both_sum of {
      left : int;
      right : int;
      bias : int;
    }
  | Small_bind_select of {
      source : int;
      even_child : int;
      odd_child : int;
      even_scale : int;
      odd_scale : int;
      bias : int;
    }

type small_graph_op =
  | Small_set of int * int
  | Small_observe of int
  | Small_dispose of int
  | Small_stabilize
  | Small_read of int

type small_graph_observer_policy =
  | Small_default_equal
  | Small_mod_equal of int

type small_graph_model = {
  small_pending : int array;
  small_committed : int array;
  small_observers : small_graph_observer array;
}

and small_graph_observer = {
  small_observed_node : int;
  small_observer_policy : small_graph_observer_policy;
  mutable small_actual_observer : int Signal.Observer.t option;
  mutable small_actual_updates : observed_update list;
  mutable small_model_active : bool;
  mutable small_model_current : int option;
  mutable small_model_updates : observed_update list;
}

let pp_small_graph_op formatter = function
  | Small_set (var, value) -> Format.fprintf formatter "Set v%d %d" var value
  | Small_observe slot -> Format.fprintf formatter "Observe slot%d" slot
  | Small_dispose slot -> Format.fprintf formatter "Dispose slot%d" slot
  | Small_stabilize -> Format.pp_print_string formatter "Stabilize"
  | Small_read slot -> Format.fprintf formatter "Read slot%d" slot

let pp_small_graph_observer_policy formatter = function
  | Small_default_equal -> Format.pp_print_string formatter "default"
  | Small_mod_equal modulus -> Format.fprintf formatter "mod%d" modulus

let small_graph_observer_equal policy left right =
  match policy with
  | Small_default_equal -> left = right
  | Small_mod_equal modulus -> left mod modulus = right mod modulus

let small_graph_apply_map ~scale ~bias value = (value * scale) + bias

let small_graph_apply_map2 ~left_scale ~right_scale ~bias left right =
  (left * left_scale) + (right * right_scale) + bias

let small_graph_eval_all ast committed =
  let values = Array.make (Array.length ast) 0 in
  Array.iteri
    (fun index node ->
      values.(index) <-
        (match node with
        | Small_var var -> committed.(var)
        | Small_map { child; scale; bias } ->
            small_graph_apply_map ~scale ~bias values.(child)
        | Small_map2 { left; right; left_scale; right_scale; bias } ->
            small_graph_apply_map2 ~left_scale ~right_scale ~bias
              values.(left) values.(right)
        | Small_all_sum { children; bias } ->
            List.fold_left (fun sum child -> sum + values.(child)) bias
              children
        | Small_both_sum { left; right; bias } ->
            values.(left) + values.(right) + bias
        | Small_bind_select
            { source; even_child; odd_child; even_scale; odd_scale; bias } ->
            if values.(source) mod 2 = 0 then
              (values.(even_child) * even_scale) + bias
            else (values.(odd_child) * odd_scale) + bias))
    ast;
  values

let create_small_graph_observer (node, policy) =
  {
    small_observed_node = node;
    small_observer_policy = policy;
    small_actual_observer = None;
    small_actual_updates = [];
    small_model_active = false;
    small_model_current = None;
    small_model_updates = [];
  }

let create_small_graph_model initial_values observer_specs =
  {
    small_pending = Array.copy initial_values;
    small_committed = Array.copy initial_values;
    small_observers = Array.map create_small_graph_observer observer_specs;
  }

let small_graph_model_stabilize ast model =
  Array.blit model.small_pending 0 model.small_committed 0
    (Array.length model.small_pending);
  let values = small_graph_eval_all ast model.small_committed in
  Array.iter
    (fun observer ->
      if observer.small_model_active then (
        let next = values.(observer.small_observed_node) in
        let update =
          match observer.small_model_current with
          | None -> Some (Initialized next)
          | Some current ->
              if
                small_graph_observer_equal observer.small_observer_policy
                  current next
              then None
              else Some (Changed (current, next))
        in
        observer.small_model_current <- Some next;
        Option.iter
          (fun update ->
            observer.small_model_updates <-
              update :: observer.small_model_updates)
          update))
    model.small_observers

let small_graph_coeff random =
  match Random.State.int random 5 with
  | 0 -> -2
  | 1 -> -1
  | 2 -> 0
  | 3 -> 1
  | _ -> 2

let small_graph_child random upper_bound = Random.State.int random upper_bound

let small_graph_children random upper_bound =
  let count = 1 + Random.State.int random (min 3 upper_bound) in
  let rec loop remaining acc =
    if remaining = 0 then acc
    else loop (remaining - 1) (small_graph_child random upper_bound :: acc)
  in
  loop count []

let small_graph_bind_select random upper_bound =
  Small_bind_select
    {
      source = small_graph_child random upper_bound;
      even_child = small_graph_child random upper_bound;
      odd_child = small_graph_child random upper_bound;
      even_scale = small_graph_coeff random;
      odd_scale = small_graph_coeff random;
      bias = Random.State.int random 7 - 3;
    }

let generate_small_graph_ast ~seed ~var_count ~node_count =
  let random = Random.State.make [| seed; node_count; var_count |] in
  Array.init node_count (fun index ->
      if index < var_count then Small_var index
      else
        match Random.State.int random 6 with
        | 0 ->
            Small_map
              {
                child = small_graph_child random index;
                scale = small_graph_coeff random;
                bias = Random.State.int random 7 - 3;
              }
        | 1 ->
            Small_map2
              {
                left = small_graph_child random index;
                right = small_graph_child random index;
                left_scale = small_graph_coeff random;
                right_scale = small_graph_coeff random;
                bias = Random.State.int random 7 - 3;
              }
        | 2 ->
            Small_all_sum
              {
                children = small_graph_children random index;
                bias = Random.State.int random 7 - 3;
              }
        | 3 -> small_graph_bind_select random index
        | 4 ->
            Small_both_sum
              {
                left = small_graph_child random index;
                right = small_graph_child random index;
                bias = Random.State.int random 7 - 3;
              }
        | _ ->
            let child = small_graph_child random index in
            Small_map2
              {
                left = child;
                right = child;
                left_scale = small_graph_coeff random;
                right_scale = small_graph_coeff random;
                bias = Random.State.int random 7 - 3;
              })

let generate_small_graph_ops ~seed ~var_count ~observer_count ~steps =
  let random =
    Random.State.make [| seed; steps; var_count; observer_count; 17 |]
  in
  let next_value () = Random.State.int random 17 - 8 in
  let next_slot () = Random.State.int random observer_count in
  let next_op index =
    if index mod 6 = 0 then Small_stabilize
    else
      match Random.State.int random 14 with
      | 0 | 1 | 2 | 3 | 4 ->
          Small_set (Random.State.int random var_count, next_value ())
      | 5 | 6 -> Small_read (next_slot ())
      | 7 | 8 -> Small_observe (next_slot ())
      | 9 | 10 -> Small_dispose (next_slot ())
      | _ -> Small_stabilize
  in
  let rec loop index acc =
    if index = steps then List.rev (Small_stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  let initial_observers =
    List.init observer_count (fun slot -> Small_observe slot)
  in
  initial_observers @ (Small_stabilize :: loop 1 [])

let small_graph_signal_of_node signals = function
  | Small_var _ -> Alcotest.fail "var node is built directly"
  | Small_map { child; scale; bias } ->
      Signal.map (small_graph_apply_map ~scale ~bias) signals.(child)
  | Small_map2 { left; right; left_scale; right_scale; bias } ->
      Signal.map2
        (small_graph_apply_map2 ~left_scale ~right_scale ~bias)
        signals.(left) signals.(right)
  | Small_all_sum { children; bias } ->
      children
      |> List.map (fun child -> signals.(child))
      |> Signal.all
      |> Signal.map (List.fold_left ( + ) bias)
  | Small_both_sum { left; right; bias } ->
      Signal.both signals.(left) signals.(right)
      |> Signal.map (fun (left, right) -> left + right + bias)
  | Small_bind_select
      { source; even_child; odd_child; even_scale; odd_scale; bias } ->
      Signal.bind signals.(source) (fun source_value ->
          if source_value mod 2 = 0 then
            Signal.map
              (fun value -> (value * even_scale) + bias)
              signals.(even_child)
          else
            Signal.map
              (fun value -> (value * odd_scale) + bias)
              signals.(odd_child))

let small_graph_random_observer_policy random =
  match Random.State.int random 4 with
  | 0 -> Small_default_equal
  | _ -> Small_mod_equal (2 + Random.State.int random 4)

let small_graph_observer_specs ~seed ~node_count ~observer_count =
  let random =
    Random.State.make [| seed; node_count; observer_count; 23 |]
  in
  Array.init observer_count (fun slot ->
      let node =
        match slot with
        | 0 -> 0
        | 1 -> node_count / 2
        | 2 -> node_count - 1
        | 3 -> node_count - 1
        | _ -> Random.State.int random node_count
      in
      let policy =
        match slot with
        | 0 | 3 -> Small_default_equal
        | _ -> small_graph_random_observer_policy random
      in
      (node, policy))

let small_graph_record observer update =
  E.sync (fun () ->
      observer.small_actual_updates <-
        observed_of_signal_update update :: observer.small_actual_updates)

let small_graph_observe runtime signals observer =
  match observer.small_actual_observer with
  | Some _ -> ()
  | None ->
      let equal =
        match observer.small_observer_policy with
        | Small_default_equal -> None
        | Small_mod_equal modulus ->
            Some (fun left right -> left mod modulus = right mod modulus)
      in
      let actual_observer =
        run_ok runtime
          (Signal.Observer.observe ?equal signals.(observer.small_observed_node)
             (small_graph_record observer))
      in
      observer.small_actual_observer <- Some actual_observer;
      observer.small_model_active <- true;
      observer.small_model_current <- None

let small_graph_dispose runtime observer =
  match observer.small_actual_observer with
  | None -> ()
  | Some actual_observer ->
      run_ok runtime (Signal.Observer.dispose actual_observer);
      observer.small_actual_observer <- None;
      observer.small_model_active <- false;
      observer.small_model_current <- None

let small_graph_check_observer label slot observer =
  Alcotest.(check (list observed_update))
    (Format.asprintf "%s slot%d node%d %a updates" label slot
       observer.small_observed_node pp_small_graph_observer_policy
       observer.small_observer_policy)
    (List.rev observer.small_model_updates)
    (List.rev observer.small_actual_updates)

let small_graph_read label runtime observer =
  match observer.small_actual_observer with
  | None -> ()
  | Some actual_observer -> (
      match observer.small_model_current with
      | None ->
          expect_uninitialized_observer label runtime
            (Signal.Observer.read actual_observer)
      | Some expected ->
          Alcotest.(check int) label expected
            (run_ok runtime (Signal.Observer.read actual_observer)))

let small_graph_check_observers label model =
  Array.iteri
    (fun slot observer -> small_graph_check_observer label slot observer)
    model.small_observers

let small_graph_active_observer_count model =
  Array.fold_left
    (fun count observer ->
      if observer.small_model_active then count + 1 else count)
    0 model.small_observers

let small_graph_check_stats label runtime model =
  let stats = run_ok runtime (Signal.stats ()) in
  Alcotest.(check int)
    (label ^ " active observers")
    (small_graph_active_observer_count model)
    stats.Signal.active_observer_count;
  Alcotest.(check int) (label ^ " invalid observers") 0
    stats.Signal.invalid_observer_count

let run_small_graph_trace ?(initial_values = [| -1; 0; 2 |])
    ?(node_count = 14) ?(observer_count = 6) ?(steps = 90) name ~seed =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let var_count = Array.length initial_values in
  let observer_specs =
    small_graph_observer_specs ~seed ~node_count ~observer_count
  in
  let ast = generate_small_graph_ast ~seed ~var_count ~node_count in
  let vars = Array.map Signal.Var.create initial_values in
  let signals = Array.make node_count (Signal.const 0) in
  Array.iteri
    (fun index node ->
      signals.(index) <-
        (match node with
        | Small_var var -> Signal.Var.watch vars.(var)
        | Small_map _ | Small_map2 _ | Small_all_sum _ | Small_both_sum _
        | Small_bind_select _ ->
            small_graph_signal_of_node signals node))
    ast;
  let model = create_small_graph_model initial_values observer_specs in
  let ops =
    generate_small_graph_ops ~seed ~var_count
      ~observer_count:(Array.length model.small_observers)
      ~steps
  in
  List.iteri
    (fun index op ->
      let label =
        Format.asprintf "%s step %d %a" name index pp_small_graph_op op
      in
      (match op with
      | Small_set (var, value) ->
          model.small_pending.(var) <- value;
          run_ok runtime (Signal.Var.set vars.(var) value)
      | Small_observe slot ->
          small_graph_observe runtime signals model.small_observers.(slot)
      | Small_dispose slot ->
          small_graph_dispose runtime model.small_observers.(slot)
      | Small_stabilize ->
          small_graph_model_stabilize ast model;
          run_ok runtime Signal.stabilize;
          small_graph_check_observers label model
      | Small_read slot ->
          small_graph_read label runtime model.small_observers.(slot));
      small_graph_check_stats label runtime model)
    ops;
  Array.iter (small_graph_dispose runtime) model.small_observers

let test_generated_small_graphs_match_model () =
  List.iter
    (fun seed ->
      run_small_graph_trace
        (Format.asprintf "small-graph-seed-%d" seed)
        ~seed)
    [ 101; 203; 307; 409; 503; 607 ]

let test_generated_larger_graphs_match_model () =
  List.iter
    (fun seed ->
      run_small_graph_trace ~initial_values:[| -1; 0; 2; 5; -3 |]
        ~node_count:30 ~observer_count:8 ~steps:120
        (Format.asprintf "larger-graph-seed-%d" seed)
        ~seed)
    [ 401; 503; 607; 719 ]

type stream_model_op =
  | Stream_set of int
  | Stream_observe of int
  | Stream_dispose of int
  | Stream_take of int
  | Stream_read of int
  | Stream_stabilize

type stream_equal_policy =
  | Stream_default_equal
  | Stream_mod_equal of int

type stream_model_slot = {
  stream_capacity : int;
  stream_equal_policy : stream_equal_policy;
  mutable stream_observer : int Signal.observer option;
  mutable stream :
    (int Signal.update, Signal.graph_error) Eta_stream.Stream.t option;
  mutable stream_current : int option;
  mutable stream_queue : observed_update list;
  mutable stream_model_drops : observed_update list;
  mutable stream_actual_drops : observed_update list;
}

let pp_stream_model_op formatter = function
  | Stream_set value -> Format.fprintf formatter "Set %d" value
  | Stream_observe slot -> Format.fprintf formatter "Observe slot%d" slot
  | Stream_dispose slot -> Format.fprintf formatter "Dispose slot%d" slot
  | Stream_take slot -> Format.fprintf formatter "Take slot%d" slot
  | Stream_read slot -> Format.fprintf formatter "Read slot%d" slot
  | Stream_stabilize -> Format.pp_print_string formatter "Stabilize"

let stream_model_equal policy left right =
  match policy with
  | Stream_default_equal -> left == right
  | Stream_mod_equal modulus -> left mod modulus = right mod modulus

let create_stream_model_slot ?(equal_policy = Stream_default_equal) capacity =
  {
    stream_capacity = capacity;
    stream_equal_policy = equal_policy;
    stream_observer = None;
    stream = None;
    stream_current = None;
    stream_queue = [];
    stream_model_drops = [];
    stream_actual_drops = [];
  }

let stream_model_slot_active slot =
  match slot.stream_observer with
  | None -> false
  | Some _ -> true

let stream_model_enqueue slot update total_drops =
  if List.length slot.stream_queue < slot.stream_capacity then
    slot.stream_queue <- slot.stream_queue @ [ update ]
  else (
    slot.stream_model_drops <- slot.stream_model_drops @ [ update ];
    incr total_drops)

let stream_model_stabilize_slot committed total_drops slot =
  if stream_model_slot_active slot then (
    let update =
      match slot.stream_current with
      | None -> Some (Initialized committed)
      | Some current ->
          if stream_model_equal slot.stream_equal_policy current committed then
            None
          else Some (Changed (current, committed))
    in
    slot.stream_current <- Some committed;
    Option.iter
      (fun update -> stream_model_enqueue slot update total_drops)
      update)

let stream_model_observe runtime signal slot =
  match slot.stream_observer with
  | Some _ -> ()
  | None ->
      let observer, stream =
        let on_drop update =
          slot.stream_actual_drops <-
            slot.stream_actual_drops @ [ observed_of_signal_update update ]
        in
        match slot.stream_equal_policy with
        | Stream_default_equal ->
            run_ok runtime
              (Signal.Stream.observe ~capacity:slot.stream_capacity ~on_drop
                 signal)
        | Stream_mod_equal _ ->
            run_ok runtime
              (Signal.Stream.observe ~capacity:slot.stream_capacity ~on_drop
                 ~equal:(stream_model_equal slot.stream_equal_policy)
                 signal)
      in
      slot.stream_observer <- Some observer;
      slot.stream <- Some stream;
      slot.stream_current <- None;
      slot.stream_queue <- []

let stream_model_pop = function
  | [] -> None
  | head :: rest -> Some (head, rest)

let stream_model_take label runtime slot =
  match (slot.stream, stream_model_pop slot.stream_queue) with
  | None, _ | Some _, None -> ()
  | Some stream, Some (expected, rest) ->
      let actual =
        run_ok runtime
          (Eta_stream.Stream.take 1 stream |> Eta_stream.run_collect)
        |> List.map observed_of_signal_update
      in
      Alcotest.(check (list observed_update)) (label ^ " taken")
        [ expected ] actual;
      slot.stream_queue <- rest

let stream_model_read label runtime slot =
  match slot.stream_observer with
  | None -> ()
  | Some observer -> (
      match slot.stream_current with
      | None ->
          expect_uninitialized_observer label runtime
            (Signal.Observer.read observer)
      | Some expected ->
          Alcotest.(check int) (label ^ " read") expected
            (run_ok runtime (Signal.Observer.read observer)))

let stream_model_dispose label runtime slot =
  match slot.stream_observer with
  | None -> ()
  | Some observer ->
      run_ok runtime (Signal.Observer.dispose observer);
      slot.stream_observer <- None;
      slot.stream_current <- None;
      (match slot.stream with
      | None -> Alcotest.fail (label ^ " missing stream")
      | Some stream ->
          let actual =
            run_ok runtime (Eta_stream.run_collect stream)
            |> List.map observed_of_signal_update
          in
          Alcotest.(check (list observed_update)) (label ^ " drained")
            slot.stream_queue actual);
      slot.stream <- None;
      slot.stream_queue <- []

let stream_model_check_slot label slot_index slot =
  Alcotest.(check (list observed_update))
    (Format.asprintf "%s slot%d drops" label slot_index)
    slot.stream_model_drops slot.stream_actual_drops

let stream_model_active_count slots =
  Array.fold_left
    (fun count slot -> if stream_model_slot_active slot then count + 1 else count)
    0 slots

let stream_model_check_stats label runtime ~base_drops ~base_active
    ~total_drops slots =
  let stats = run_ok runtime (Signal.stats ()) in
  Alcotest.(check int) (label ^ " active observers")
    (base_active + stream_model_active_count slots)
    stats.Signal.active_observer_count;
  Alcotest.(check int) (label ^ " stream drops")
    (base_drops + !total_drops)
    stats.Signal.stream_bridge_drop_count

let generate_stream_model_ops ~seed ~slot_count ~steps =
  let random = Random.State.make [| seed; slot_count; steps; 41 |] in
  let next_slot () = Random.State.int random slot_count in
  let next_value () = Random.State.int random 21 - 10 in
  let next_op index =
    if index mod 5 = 0 then Stream_stabilize
    else
      match Random.State.int random 14 with
      | 0 | 1 | 2 | 3 | 4 -> Stream_set (next_value ())
      | 5 | 6 -> Stream_take (next_slot ())
      | 7 | 8 -> Stream_read (next_slot ())
      | 9 | 10 -> Stream_observe (next_slot ())
      | 11 | 12 -> Stream_dispose (next_slot ())
      | _ -> Stream_stabilize
  in
  let rec loop index acc =
    if index = steps then List.rev (Stream_stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  List.init slot_count (fun slot -> Stream_observe slot)
  @ [
      Stream_stabilize;
      Stream_read 0;
      Stream_read 1;
      Stream_read 2;
      Stream_read 3;
      Stream_take 0;
      Stream_take 1;
      Stream_set 3;
      Stream_stabilize;
      Stream_read 0;
      Stream_take 0;
      Stream_dispose 0;
      Stream_set 4;
      Stream_stabilize;
      Stream_read 1;
      Stream_take 1;
      Stream_take 1;
      Stream_set 5;
      Stream_stabilize;
      Stream_set 6;
      Stream_stabilize;
      Stream_read 3;
      Stream_take 3;
      Stream_set 7;
      Stream_stabilize;
      Stream_read 3;
      Stream_take 3;
    ]
  @ loop 1 []

let run_stream_model_trace name ~seed =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 0 in
  let signal = Signal.Var.watch source in
  let slots =
    [| create_stream_model_slot 1; create_stream_model_slot 2;
       create_stream_model_slot ~equal_policy:(Stream_mod_equal 3) 3;
       create_stream_model_slot 1; create_stream_model_slot 4 |]
  in
  let base_stats = run_ok runtime (Signal.stats ()) in
  let base_drops = base_stats.Signal.stream_bridge_drop_count in
  let base_active = base_stats.Signal.active_observer_count in
  let total_drops = ref 0 in
  let pending = ref 0 in
  let committed = ref 0 in
  let ops =
    generate_stream_model_ops ~seed ~slot_count:(Array.length slots)
      ~steps:100
  in
  List.iteri
    (fun index op ->
      let label =
        Format.asprintf "%s step %d %a" name index pp_stream_model_op op
      in
      (match op with
      | Stream_set value ->
          pending := value;
          run_ok runtime (Signal.Var.set source value)
      | Stream_observe slot ->
          stream_model_observe runtime signal slots.(slot)
      | Stream_dispose slot ->
          stream_model_dispose label runtime slots.(slot)
      | Stream_take slot ->
          stream_model_take label runtime slots.(slot)
      | Stream_read slot ->
          stream_model_read label runtime slots.(slot)
      | Stream_stabilize ->
          committed := !pending;
          Array.iter
            (stream_model_stabilize_slot !committed total_drops)
            slots;
          run_ok runtime Signal.stabilize);
      Array.iteri (stream_model_check_slot label) slots;
      stream_model_check_stats label runtime ~base_drops ~base_active
        ~total_drops slots)
    ops;
  Array.iteri
    (fun slot_index slot ->
      stream_model_dispose
        (Format.asprintf "%s final slot%d" name slot_index)
        runtime slot)
    slots;
  stream_model_check_stats (name ^ " final") runtime ~base_drops ~base_active
    ~total_drops slots

let test_stream_bridge_trace_matches_model () =
  List.iter
    (fun seed ->
      run_stream_model_trace
        (Format.asprintf "stream-bridge-seed-%d" seed)
        ~seed)
    [ 17; 37; 73; 109; 211 ]

let () =
  Alcotest.run "eta_signal_model"
    [
      ( "model",
        [
          Alcotest.test_case "scripted trace matches model" `Quick
            test_scripted_trace_matches_model;
          Alcotest.test_case "randomized trace matches model" `Quick
            test_randomized_trace_matches_model;
          Alcotest.test_case
            "time now/after/interval lifecycle trace matches model" `Quick
            test_time_now_after_interval_lifecycle_trace_matches_model;
          Alcotest.test_case "time bind demand trace matches model" `Quick
            test_time_bind_demand_trace_matches_model;
          Alcotest.test_case "coalesced sets match model" `Quick
            test_coalesced_sets_match_model;
          Alcotest.test_case "effectful update trace matches model" `Quick
            test_effectful_update_trace_matches_model;
          Alcotest.test_case "source equality trace matches model" `Quick
            test_source_equality_trace_matches_model;
          Alcotest.test_case
            "derived observer and bind cutoff trace matches model" `Quick
            test_derived_observer_and_bind_cutoff_trace_matches_model;
          Alcotest.test_case "observer-phase mutation matches model" `Quick
            test_observer_phase_mutation_matches_model;
          Alcotest.test_case "observer failure retry matches model" `Quick
            test_observer_failure_retry_matches_model;
          Alcotest.test_case "pure failure matches model" `Quick
            test_pure_failure_matches_model;
          Alcotest.test_case "dynamic cycle preserves snapshot" `Quick
            test_dynamic_cycle_preserves_snapshot_matches_model;
          Alcotest.test_case "dispose demand matches model" `Quick
            test_dispose_demand_matches_model;
          Alcotest.test_case "observer lifecycle trace matches model" `Quick
            test_observer_lifecycle_trace_matches_model;
          Alcotest.test_case "bind branch demand trace matches model" `Quick
            test_bind_branch_demand_trace_matches_model;
          Alcotest.test_case "nested bind churn trace matches model" `Quick
            test_nested_bind_churn_trace_matches_model;
          Alcotest.test_case "retained branch trace matches model" `Quick
            test_retained_branch_trace_matches_model;
          Alcotest.test_case "diamond trace matches model" `Quick
            test_diamond_trace_matches_model;
          Alcotest.test_case
            "generated small graphs with observers and stats match model" `Quick
            test_generated_small_graphs_match_model;
          Alcotest.test_case
            "generated larger graphs with observers and stats match model" `Quick
            test_generated_larger_graphs_match_model;
          Alcotest.test_case "stream bridge trace matches model" `Quick
            test_stream_bridge_trace_matches_model;
        ] );
    ]
