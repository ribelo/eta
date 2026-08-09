open! Core

type mutable_counters = {
  mutable actions : int;
  mutable transitions : int;
  mutable driver_cycles : int;
  mutable observations : int;
  mutable projections : int;
  mutable child_visits : int;
  mutable changed_rows : int;
}

let make_counters () =
  {
    actions = 0;
    transitions = 0;
    driver_cycles = 0;
    observations = 0;
    projections = 0;
    child_visits = 0;
    changed_rows = 0;
  }

let snapshot counters : Bench_common.counters =
  {
    actions = counters.actions;
    transitions = counters.transitions;
    driver_cycles = counters.driver_cycles;
    observations = counters.observations;
    projections = counters.projections;
    child_visits = counters.child_visits;
    changed_rows = counters.changed_rows;
  }

let expected ?(projections = 0) ?(child_visits = 0)
    ?(changed_rows = 0) () : Bench_common.counters =
  {
    actions = 1;
    transitions = 1;
    driver_cycles = 1;
    observations = 1;
    projections;
    child_visits;
    changed_rows;
  }

let create_driver component =
  let time_source = Bonsai.Time_source.create ~start:Time_ns.epoch in
  Bonsai_driver.create
    ~instrumentation:(Bonsai_driver.Instrumentation.default_for_test_handles ())
    ~time_source component

let initialize driver =
  Bonsai_driver.flush driver;
  let output = Bonsai_driver.result driver in
  Bonsai_driver.trigger_lifecycles driver;
  output

let run_operation counters driver inject action observe =
  counters.actions <- counters.actions + 1;
  Bonsai_driver.schedule_event driver (inject action);
  Bonsai_driver.flush driver;
  counters.driver_cycles <- counters.driver_cycles + 1;
  let output = Bonsai_driver.result driver in
  counters.observations <- counters.observations + 1;
  observe output;
  Bonsai_driver.trigger_lifecycles driver

let scalar_workload ~equal_model =
  let counters = make_counters () in
  let component (local_ graph) =
    let model, inject =
      Bonsai.state_machine
        ~equal:Int.equal
        ~default_model:0
        ~apply_action:(fun _context model action ->
          counters.transitions <- counters.transitions + 1;
          if equal_model then model else model + action)
        graph
    in
    let projected =
      Bonsai.cutoff model ~equal:Int.equal
      |> Bonsai.map ~f:(fun value ->
             counters.projections <- counters.projections + 1;
             value)
    in
    Bonsai.map2 projected inject ~f:(fun value inject -> (value, inject))
  in
  let driver = create_driver component in
  let initial, inject = initialize driver in
  if initial <> 0 then failwith "Bonsai scalar initial output differs";
  let direction = ref 1 in
  let expected_model = ref 0 in
  let observe (model, _) =
    if model <> !expected_model then
      failwith "Bonsai scalar output sequence differs";
    ignore (Sys.opaque_identity model)
  in
  {
    Bench_common.expected_per_operation =
      expected ~projections:(if equal_model then 0 else 1) ();
    snapshot = (fun () -> snapshot counters);
    isolated_operations = false;
    set_full_validation = (fun _ -> ());
    prepare_batch = (fun () -> ());
    run_batch =
      (fun ~operations ->
        for _ = 1 to operations do
          let action = if equal_model then 1 else !direction in
          if not equal_model then (
            expected_model := !expected_model + action;
            direction := - !direction);
          run_operation counters driver inject action observe
        done);
    finish_batch = (fun () -> ());
    teardown = (fun () -> Bonsai_driver.Expert.invalidate_observers driver);
  }

let assoc_workload size =
  let counters = make_counters () in
  let middle = size / 2 in
  let base =
    List.init size ~f:(fun key -> key, 0)
    |> Int.Map.of_alist_exn
  in
  let changed = Map.set base ~key:middle ~data:1 in
  let component (local_ graph) =
    let model, inject =
      Bonsai.state_machine
        ~equal:phys_equal
        ~default_model:base
        ~apply_action:(fun _context _model action ->
          counters.transitions <- counters.transitions + 1;
          if action then changed else base)
        graph
    in
    let children =
      Bonsai.assoc
        (module Int)
        model
        ~f:(fun _key data (local_ _graph) ->
          Bonsai.map data ~f:(fun value ->
              counters.child_visits <- counters.child_visits + 1;
              value))
        graph
    in
    Bonsai.map2 children inject ~f:(fun output inject -> (output, inject))
  in
  let driver = create_driver component in
  let initial, inject = initialize driver in
  if Map.length initial <> size then
    failwith "Bonsai assoc initial cardinality differs";
  let use_changed = ref true in
  let expected_middle = ref 0 in
  let expected_output = ref base in
  let full_validation = ref false in
  let observe (output, _) =
    if Map.length output <> size then
      failwith "Bonsai assoc output cardinality differs";
    let value = Map.find_exn output middle in
    if value <> !expected_middle then
      failwith "Bonsai assoc middle row differs";
    if !full_validation && not (Map.equal Int.equal output !expected_output) then
      failwith "Bonsai assoc output map differs";
    counters.changed_rows <- counters.changed_rows + 1;
    ignore (Sys.opaque_identity value)
  in
  {
    Bench_common.expected_per_operation =
      expected ~child_visits:1 ~changed_rows:1 ();
    snapshot = (fun () -> snapshot counters);
    isolated_operations = false;
    set_full_validation = (fun value -> full_validation := value);
    prepare_batch = (fun () -> ());
    run_batch =
      (fun ~operations ->
        for _ = 1 to operations do
          let action = !use_changed in
          expected_middle := if action then 1 else 0;
          expected_output := if action then changed else base;
          use_changed := not !use_changed;
          run_operation counters driver inject action observe
        done);
    finish_batch = (fun () -> ());
    teardown = (fun () -> Bonsai_driver.Expert.invalidate_observers driver);
  }

let startup_workload () =
  let counters = make_counters () in
  let drivers = ref [] in
  let component (local_ graph) =
    let model, inject =
      Bonsai.state_machine
        ~equal:Int.equal
        ~default_model:0
        ~apply_action:(fun _context model action -> model + action)
        graph
    in
    let projected =
      Bonsai.map model ~f:(fun value ->
          counters.projections <- counters.projections + 1;
          value)
    in
    Bonsai.map2 projected inject ~f:(fun value inject -> (value, inject))
  in
  let create_once () =
    let driver = create_driver component in
    drivers := driver :: !drivers;
    let model, _inject = initialize driver in
    counters.driver_cycles <- counters.driver_cycles + 1;
    counters.observations <- counters.observations + 1;
    if model <> 0 then failwith "Bonsai startup output differs";
    ignore (Sys.opaque_identity model)
  in
  let clear () =
    List.iter !drivers ~f:Bonsai_driver.Expert.invalidate_observers;
    drivers := []
  in
  {
    Bench_common.expected_per_operation =
      { (expected ~projections:1 ()) with actions = 0; transitions = 0 };
    snapshot = (fun () -> snapshot counters);
    isolated_operations = true;
    set_full_validation = (fun _ -> ());
    prepare_batch =
      (fun () ->
        if not (List.is_empty !drivers) then
          failwith "Bonsai startup drivers were not cleared");
    run_batch =
      (fun ~operations ->
        if operations <> 1 then
          invalid_arg "startup.root requires exactly one operation per sample";
        for _ = 1 to operations do
          create_once ()
        done);
    finish_batch = clear;
    teardown = clear;
  }

let workloads =
  [
    Bench_common.workload "scalar.changed" (fun () ->
        scalar_workload ~equal_model:false);
    Bench_common.workload "scalar.equal" (fun () ->
        scalar_workload ~equal_model:true);
    Bench_common.workload "assoc.changed.1000" (fun () ->
        assoc_workload 1_000);
    Bench_common.workload "assoc.changed.10000" (fun () ->
        assoc_workload 10_000);
    Bench_common.workload "startup.root" startup_workload;
  ]

let () = Bench_common.main ~framework:"bonsai" workloads
