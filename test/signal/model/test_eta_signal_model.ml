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
  | Signal.stabilize_error ]

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

let expect_observer_failed label runtime eff =
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Error (Eta.Cause.Fail (`Observer_error `Observer_failed)) -> ()
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected observer failure, got Ok" label
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected observer failure, got %a" label
        (Eta.Cause.pp pp_hidden) cause

let expect_die label runtime eff =
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Error (Eta.Cause.Die _) -> ()
  | Eta.Exit.Ok _ -> Alcotest.failf "%s: expected die, got Ok" label
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected die, got %a" label
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
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let source = Signal.Var.create 0 in
  let signal = Signal.Var.watch source in
  let delivered_updates = ref [] in
  let fail_next_change = ref false in
  let callback update =
    match update with
    | Signal.Changed _ when !fail_next_change ->
        fail_next_change := false;
        E.fail `Observer_failed
    | Signal.Initialized _ | Signal.Changed _ ->
        E.sync (fun () ->
            delivered_updates :=
              observed_of_signal_update update :: !delivered_updates)
  in
  let observer = run_ok runtime (Signal.Observer.observe signal callback) in
  let model_current = ref None in
  let delivered_model = ref [] in
  let pending_delivery = ref None in
  let commit_model value =
    let update =
      match !model_current with
      | None -> Initialized value
      | Some current -> Changed (current, value)
    in
    model_current := Some value;
    pending_delivery := Some update
  in
  let deliver_model () =
    match !pending_delivery with
    | None -> ()
    | Some update ->
        delivered_model := update :: !delivered_model;
        pending_delivery := None
  in
  commit_model 0;
  deliver_model ();
  run_ok runtime Signal.stabilize;
  Alcotest.(check (list observed_update))
    "initial delivery" (List.rev !delivered_model)
    (List.rev !delivered_updates);
  fail_next_change := true;
  run_ok runtime (Signal.Var.set source 1);
  commit_model 1;
  expect_observer_failed "failed delivery" runtime Signal.stabilize;
  Alcotest.(check int) "failed delivery still commits current snapshot" 1
    (run_ok runtime (Signal.Observer.read observer));
  Alcotest.(check (list observed_update))
    "failed delivery is still pending" (List.rev !delivered_model)
    (List.rev !delivered_updates);
  deliver_model ();
  run_ok runtime Signal.stabilize;
  Alcotest.(check (list observed_update))
    "retry delivery" (List.rev !delivered_model)
    (List.rev !delivered_updates);
  Alcotest.(check int) "retry keeps committed snapshot" 1
    (run_ok runtime (Signal.Observer.read observer));
  run_ok runtime (Signal.Observer.dispose observer)

let test_pure_failure_matches_model () =
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
    | None -> ()
    | Some expected ->
        Alcotest.(check int) (label ^ " read") expected
          (run_ok runtime (Signal.Observer.read observer))
  in
  Alcotest.(check bool) "initial model commits" true
    (match stabilize_model () with `Committed -> true | `Pure_failure -> false);
  run_ok runtime Signal.stabilize;
  check_model "initial";
  model_pending := 2;
  run_ok runtime (Signal.Var.set source 2);
  Alcotest.(check bool) "failing model does not commit" true
    (match stabilize_model () with `Pure_failure -> true | `Committed -> false);
  expect_die "pure failure" runtime Signal.stabilize;
  check_model "after pure failure";
  Alcotest.(check bool) "pending failure retries" true
    (match stabilize_model () with `Pure_failure -> true | `Committed -> false);
  expect_die "pure failure retry" runtime Signal.stabilize;
  check_model "after pure failure retry";
  model_pending := 3;
  run_ok runtime (Signal.Var.set source 3);
  Alcotest.(check bool) "recovered model commits" true
    (match stabilize_model () with `Committed -> true | `Pure_failure -> false);
  run_ok runtime Signal.stabilize;
  check_model "after recovery";
  run_ok runtime (Signal.Observer.dispose observer)

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
  let first_observer =
    run_ok runtime (Signal.Observer.observe signal (record first_updates))
  in
  let model_pending = ref 0 in
  let model_recomputes = ref 0 in
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
  stabilize_model ~demanded:true first_model_current first_model_updates;
  run_ok runtime Signal.stabilize;
  Alcotest.(check int) "initial recompute" !model_recomputes !recomputes;
  check_updates "first observer initialized" first_model_updates first_updates;
  Alcotest.(check int) "first read" 0
    (run_ok runtime (Signal.Observer.read first_observer));
  run_ok runtime (Signal.Observer.dispose first_observer);
  model_pending := 1;
  run_ok runtime (Signal.Var.set source 1);
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
  Alcotest.(check int) "second read" 1
    (run_ok runtime (Signal.Observer.read second_observer));
  run_ok runtime (Signal.Observer.dispose second_observer)

let () =
  Alcotest.run "eta_signal_model"
    [
      ( "model",
        [
          Alcotest.test_case "scripted trace matches model" `Quick
            test_scripted_trace_matches_model;
          Alcotest.test_case "randomized trace matches model" `Quick
            test_randomized_trace_matches_model;
          Alcotest.test_case "observer-phase mutation matches model" `Quick
            test_observer_phase_mutation_matches_model;
          Alcotest.test_case "observer failure retry matches model" `Quick
            test_observer_failure_retry_matches_model;
          Alcotest.test_case "pure failure matches model" `Quick
            test_pure_failure_matches_model;
          Alcotest.test_case "dispose demand matches model" `Quick
            test_dispose_demand_matches_model;
        ] );
    ]
