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
          Alcotest.test_case "observer lifecycle trace matches model" `Quick
            test_observer_lifecycle_trace_matches_model;
          Alcotest.test_case "bind branch demand trace matches model" `Quick
            test_bind_branch_demand_trace_matches_model;
          Alcotest.test_case "diamond trace matches model" `Quick
            test_diamond_trace_matches_model;
        ] );
    ]
