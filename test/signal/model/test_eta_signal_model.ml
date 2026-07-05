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

let expect_uninitialized_observer label runtime eff =
  match Eta.Runtime.run runtime (widen eff) with
  | Eta.Exit.Error (Eta.Cause.Fail `Uninitialized_observer) -> ()
  | Eta.Exit.Ok _ ->
      Alcotest.failf "%s: expected uninitialized observer, got Ok" label
  | Eta.Exit.Error cause ->
      Alcotest.failf "%s: expected uninitialized observer, got %a" label
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
  let pp_delivery_op formatter = function
    | `Set value -> Format.fprintf formatter "Set %d" value
    | `Fail_next -> Format.pp_print_string formatter "Fail_next"
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
        | 5 | 6 -> `Read
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
    let delivered_updates = ref [] in
    let fail_next_delivery = ref false in
    let callback update =
      if !fail_next_delivery then (
        fail_next_delivery := false;
        E.fail `Observer_failed)
      else
        E.sync (fun () ->
            delivered_updates :=
              observed_of_signal_update update :: !delivered_updates)
    in
    let observer = run_ok runtime (Signal.Observer.observe signal callback) in
    let model_pending = ref 0 in
    let model_current = ref None in
    let model_delivery =
      ref
        (`Never :
          [ `Delivered of int | `Never | `Pending of observed_update ])
    in
    let model_delivered = ref [] in
    let model_fail_next = ref false in
    let stabilize_model () =
      let next = !model_pending in
      let changed =
        match !model_current with
        | None -> true
        | Some current -> current <> next
      in
      model_current := Some next;
      let update =
        match delivery_base !model_delivery with
        | None -> Some (Initialized next)
        | Some base ->
            if changed || delivery_pending !model_delivery then
              if base = next then (
                model_delivery := `Delivered next;
                None)
              else Some (Changed (base, next))
            else None
      in
      match update with
      | None -> `Ok
      | Some update ->
          model_delivery := `Pending update;
          if !model_fail_next then (
            model_fail_next := false;
            `Observer_failed)
          else (
            model_delivered := update :: !model_delivered;
            model_delivery := `Delivered (delivered_value update);
            `Ok)
    in
    let check_delivered label =
      Alcotest.(check (list observed_update))
        (label ^ " delivered") (List.rev !model_delivered)
        (List.rev !delivered_updates)
    in
    let check_read label =
      match !model_current with
      | None -> ()
      | Some expected ->
          Alcotest.(check int) (label ^ " read") expected
            (run_ok runtime (Signal.Observer.read observer))
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
            model_fail_next := true;
            fail_next_delivery := true
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
                check_read label))
      ops;
    run_ok runtime (Signal.Observer.dispose observer)
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
      `Set 1;
      `Stabilize;
    ]
  in
  run_delivery_trace "observer-failure-scripted" scripted;
  List.iter
    (fun seed ->
      run_delivery_trace
        (Format.asprintf "observer-failure-seed-%d" seed)
        (generate_delivery_trace ~seed ~steps:36))
    [ 11; 23; 37; 41; 53 ]

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
  model.committed_choose_a <- model.pending_choose_a;
  let value = compute_branch_if_needed (selected_branch_model model) in
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
  let source_a = Signal.Var.create 0 in
  let source_b = Signal.Var.create 10 in
  let choose_a = Signal.Var.create true in
  let recomputes_a = ref 0 in
  let recomputes_b = ref 0 in
  let branch_a =
    Signal.Var.watch source_a
    |> Signal.map (fun value ->
           incr recomputes_a;
           value)
  in
  let branch_b =
    Signal.Var.watch source_b
    |> Signal.map (fun value ->
           incr recomputes_b;
           value)
  in
  let selected =
    Signal.bind (Signal.Var.watch choose_a) (fun use_a ->
        if use_a then branch_a else branch_b)
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
          check_bind_demand_model label model updates recomputes_a recomputes_b
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
  | Small_stabilize
  | Small_read

type small_graph_model = {
  small_pending : int array;
  small_committed : int array;
  mutable small_current : int option;
  mutable small_updates : observed_update list;
}

let pp_small_graph_op formatter = function
  | Small_set (var, value) -> Format.fprintf formatter "Set v%d %d" var value
  | Small_stabilize -> Format.pp_print_string formatter "Stabilize"
  | Small_read -> Format.pp_print_string formatter "Read"

let small_graph_apply_map ~scale ~bias value = (value * scale) + bias

let small_graph_apply_map2 ~left_scale ~right_scale ~bias left right =
  (left * left_scale) + (right * right_scale) + bias

let small_graph_eval ast committed =
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
        | Small_bind_select
            { source; even_child; odd_child; even_scale; odd_scale; bias } ->
            if values.(source) mod 2 = 0 then
              (values.(even_child) * even_scale) + bias
            else (values.(odd_child) * odd_scale) + bias))
    ast;
  values.(Array.length values - 1)

let create_small_graph_model initial_values =
  {
    small_pending = Array.copy initial_values;
    small_committed = Array.copy initial_values;
    small_current = None;
    small_updates = [];
  }

let small_graph_model_stabilize ast model =
  Array.blit model.small_pending 0 model.small_committed 0
    (Array.length model.small_pending);
  let next = small_graph_eval ast model.small_committed in
  let update =
    match model.small_current with
    | None -> Some (Initialized next)
    | Some current ->
        if current = next then None else Some (Changed (current, next))
  in
  model.small_current <- Some next;
  Option.iter
    (fun update -> model.small_updates <- update :: model.small_updates)
    update

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
        match Random.State.int random 5 with
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

let generate_small_graph_ops ~seed ~var_count ~steps =
  let random = Random.State.make [| seed; steps; var_count; 17 |] in
  let next_value () = Random.State.int random 17 - 8 in
  let next_op index =
    if index mod 6 = 0 then Small_stabilize
    else
      match Random.State.int random 10 with
      | 0 | 1 | 2 | 3 | 4 ->
          Small_set (Random.State.int random var_count, next_value ())
      | 5 | 6 -> Small_read
      | _ -> Small_stabilize
  in
  let rec loop index acc =
    if index = steps then List.rev (Small_stabilize :: acc)
    else loop (index + 1) (next_op index :: acc)
  in
  Small_stabilize :: loop 1 []

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

let run_small_graph_trace name ~seed =
  Eta_test.with_test_clock @@ fun _sw _clock runtime ->
  let var_count = 3 in
  let node_count = 14 in
  let initial_values = [| -1; 0; 2 |] in
  let ast = generate_small_graph_ast ~seed ~var_count ~node_count in
  let vars = Array.map Signal.Var.create initial_values in
  let signals = Array.make node_count (Signal.const 0) in
  Array.iteri
    (fun index node ->
      signals.(index) <-
        (match node with
        | Small_var var -> Signal.Var.watch vars.(var)
        | Small_map _ | Small_map2 _ | Small_all_sum _ | Small_bind_select _ ->
            small_graph_signal_of_node signals node))
    ast;
  let updates = ref [] in
  let record update =
    E.sync (fun () ->
        updates := observed_of_signal_update update :: !updates)
  in
  let observer =
    run_ok runtime
      (Signal.Observer.observe signals.(node_count - 1) record)
  in
  let model = create_small_graph_model initial_values in
  let ops = generate_small_graph_ops ~seed ~var_count ~steps:90 in
  List.iteri
    (fun index op ->
      let label =
        Format.asprintf "%s step %d %a" name index pp_small_graph_op op
      in
      match op with
      | Small_set (var, value) ->
          model.small_pending.(var) <- value;
          run_ok runtime (Signal.Var.set vars.(var) value)
      | Small_stabilize ->
          small_graph_model_stabilize ast model;
          run_ok runtime Signal.stabilize;
          Alcotest.(check (list observed_update))
            (label ^ " updates") (List.rev model.small_updates)
            (List.rev !updates)
      | Small_read -> (
          match model.small_current with
          | None ->
              expect_uninitialized_observer label runtime
                (Signal.Observer.read observer)
          | Some expected ->
              Alcotest.(check int) label expected
                (run_ok runtime (Signal.Observer.read observer))))
    ops;
  run_ok runtime (Signal.Observer.dispose observer)

let test_generated_small_graphs_match_model () =
  List.iter
    (fun seed ->
      run_small_graph_trace
        (Format.asprintf "small-graph-seed-%d" seed)
        ~seed)
    [ 101; 203; 307; 409; 503; 607 ]

let () =
  Alcotest.run "eta_signal_model"
    [
      ( "model",
        [
          Alcotest.test_case "scripted trace matches model" `Quick
            test_scripted_trace_matches_model;
          Alcotest.test_case "randomized trace matches model" `Quick
            test_randomized_trace_matches_model;
          Alcotest.test_case "coalesced sets match model" `Quick
            test_coalesced_sets_match_model;
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
          Alcotest.test_case "generated small graphs match model" `Quick
            test_generated_small_graphs_match_model;
        ] );
    ]
