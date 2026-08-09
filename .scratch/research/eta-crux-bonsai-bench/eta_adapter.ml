module Crux = Eta_crux

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

let run_ok runtime effect =
  match Eta.Runtime.run runtime effect with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith
        (Eta.Cause.pp_compact
           (fun (value : Eta_crux.never) -> match value with _ -> .)
           cause)

let start_initial runtime root =
  match run_ok runtime (Crux.Root.advance root) with
  | Ok
      (Crux.Root.Committed
        { output; post_commit }) ->
      let result =
        run_ok runtime
          (Crux.Post_commit.start post_commit
          |> Eta.Effect.or_die (fun Crux.Post_commit.Already_started ->
                 Invalid_argument "initial post-commit token was already started"))
      in
      ignore result;
      output
  | Ok Crux.Root.Idle
  | Ok (Crux.Root.Rejected _)
  | Ok (Crux.Root.Failed _)
  | Ok (Crux.Root.Stopped _)
  | Error _ ->
      failwith "Eta Crux benchmark failed to start the root"

let stop_root runtime root =
  Crux.Root.request_stop root;
  match run_ok runtime (Crux.Root.advance root) with
  | Ok (Crux.Root.Stopped { post_commit }) ->
      ignore
        (run_ok runtime
           (Crux.Post_commit.start post_commit
           |> Eta.Effect.or_die (fun Crux.Post_commit.Already_started ->
                  Invalid_argument "stop post-commit token was already started")))
  | Ok Crux.Root.Idle
  | Ok (Crux.Root.Rejected _)
  | Ok (Crux.Root.Committed _)
  | Ok (Crux.Root.Failed _)
  | Error _ ->
      failwith "Eta Crux benchmark failed to stop the root"

let operation_effect counters root endpoint action observe =
  let open Eta.Syntax in
  counters.actions <- counters.actions + 1;
  let* () =
    Crux.Endpoint.send endpoint action
    |> Eta.Effect.or_die (function
         | Crux.Endpoint.Ingress_closed ->
             Failure "Eta Crux benchmark ingress closed")
  in
  let* result = Crux.Root.advance root in
  match result with
  | Ok
      (Crux.Root.Committed
        { output; post_commit }) ->
      counters.driver_cycles <- counters.driver_cycles + 1;
      counters.observations <- counters.observations + 1;
      observe output;
      Crux.Post_commit.start post_commit
      |> Eta.Effect.or_die (fun Crux.Post_commit.Already_started ->
             Invalid_argument "post-commit token was already started")
      |> Eta.Effect.map (fun _ -> ())
  | Ok Crux.Root.Idle
  | Ok (Crux.Root.Rejected _)
  | Ok (Crux.Root.Failed _)
  | Ok (Crux.Root.Stopped _)
  | Error _ ->
      Eta.Effect.die_message "Eta Crux benchmark advancement did not commit"

let run_effect_batch runtime operations make_effect =
  let rec loop index =
    if index = operations then Eta.Effect.unit
    else Eta.Effect.bind (fun () -> loop (index + 1)) (make_effect index)
  in
  run_ok runtime (loop 0)

let scalar_workload runtime ~equal_model =
  let counters = make_counters () in
  let machine =
    Crux.State_machine.create
      ~model_cutoff:(Crux.Cutoff.of_equal Int.equal)
      (Crux.return ()) ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
        counters.transitions <- counters.transitions + 1;
        ((if equal_model then model else model + action), Eta.Effect.unit))
  in
  let projected =
    Crux.map machine ~f:fst
    |> Crux.cutoff ~cutoff:(Crux.Cutoff.of_equal Int.equal)
    |> Crux.map ~f:(fun model ->
           counters.projections <- counters.projections + 1;
           model)
  in
  let description = Crux.both projected (Crux.map machine ~f:snd) in
  let root =
    Crux.Root.create ~ingress_capacity:8 ~request_capacity:1 description
  in
  let initial_model, endpoint = start_initial runtime root in
  if initial_model <> 0 then failwith "Eta Crux scalar initial output differs";
  let direction = ref 1 in
  let expected_model = ref 0 in
  let observe (model, _) =
    if model <> !expected_model then
      failwith "Eta Crux scalar output sequence differs";
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
        run_effect_batch runtime operations (fun _index ->
            let action = if equal_model then 1 else !direction in
            if not equal_model then (
              expected_model := !expected_model + action;
              direction := - !direction);
            operation_effect counters root endpoint action observe));
    finish_batch = (fun () -> ());
    teardown = (fun () -> stop_root runtime root);
  }

module Int_order = struct
  type t = int

  let compare = Int.compare
end

module Int_map = Eta_signal_map.Map.Make (Int_order)
module Assoc = Crux.Assoc (Int_order)

let map_of_list_exn values =
  match Int_map.of_list values with
  | Ok map -> map
  | Error (`Duplicate_key key) ->
      invalid_arg (Printf.sprintf "duplicate benchmark key %d" key)

let assoc_workload runtime size =
  let counters = make_counters () in
  let middle = size / 2 in
  let base = List.init size (fun key -> (key, 0)) |> map_of_list_exn in
  let changed = Int_map.set middle 1 base in
  let machine =
    Crux.State_machine.create
      ~model_cutoff:Crux.Cutoff.phys_equal
      (Crux.return ()) ~default_model:base
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action ->
        counters.transitions <- counters.transitions + 1;
        ((if action then changed else base), Eta.Effect.unit))
  in
  let children =
    Assoc.assoc
      ~data_cutoff:(Crux.Cutoff.of_equal Int.equal)
      (Crux.map machine ~f:fst)
      ~f:(fun ~key:_ ~data ->
        Crux.map data ~f:(fun value ->
            counters.child_visits <- counters.child_visits + 1;
            value))
  in
  let description = Crux.both children (Crux.map machine ~f:snd) in
  let root =
    Crux.Root.create ~ingress_capacity:8 ~request_capacity:1 description
  in
  let initial, endpoint = start_initial runtime root in
  if Int_map.cardinal initial <> size then
    failwith "Eta Crux assoc initial cardinality differs";
  let use_changed = ref true in
  let expected_middle = ref 0 in
  let expected_output = ref base in
  let full_validation = ref false in
  let observe (output, _) =
    if Int_map.cardinal output <> size then
      failwith "Eta Crux assoc output cardinality differs";
    let value =
      match Int_map.find_opt middle output with
      | Some value -> value
      | None -> failwith "Eta Crux assoc output has no middle key"
    in
    if value <> !expected_middle then
      failwith "Eta Crux assoc middle row differs";
    if !full_validation && not (Int_map.equal Int.equal output !expected_output)
    then failwith "Eta Crux assoc output map differs";
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
        run_effect_batch runtime operations (fun _index ->
            let action = !use_changed in
            expected_middle := if action then 1 else 0;
            expected_output := if action then changed else base;
            use_changed := not !use_changed;
            operation_effect counters root endpoint action observe));
    finish_batch = (fun () -> ());
    teardown = (fun () -> stop_root runtime root);
  }

let startup_workload runtime =
  let counters = make_counters () in
  let roots = ref [] in
  let create_once () =
    let machine =
      Crux.State_machine.create
        ~model_cutoff:(Crux.Cutoff.of_equal Int.equal)
        (Crux.return ()) ~default_model:0
        ~apply_action:(fun ~self:_ ~input:() ~model ~action ->
          (model + action, Eta.Effect.unit))
    in
    let description =
      Crux.both
        (Crux.map machine ~f:(fun (model, _) ->
             counters.projections <- counters.projections + 1;
             model))
        (Crux.map machine ~f:snd)
    in
    let root =
      Crux.Root.create ~ingress_capacity:1 ~request_capacity:1 description
    in
    roots := root :: !roots;
    let model, _endpoint = start_initial runtime root in
    counters.driver_cycles <- counters.driver_cycles + 1;
    counters.observations <- counters.observations + 1;
    if model <> 0 then failwith "Eta Crux startup output differs";
    ignore (Sys.opaque_identity model)
  in
  {
    Bench_common.expected_per_operation =
      { (expected ~projections:1 ()) with actions = 0; transitions = 0 };
    snapshot = (fun () -> snapshot counters);
    isolated_operations = true;
    set_full_validation = (fun _ -> ());
    prepare_batch =
      (fun () ->
        if !roots <> [] then failwith "Eta Crux startup roots were not cleared");
    run_batch =
      (fun ~operations ->
        if operations <> 1 then
          invalid_arg "startup.root requires exactly one operation per sample";
        for _ = 1 to operations do
          create_once ()
        done);
    finish_batch =
      (fun () ->
        List.iter (stop_root runtime) !roots;
        roots := []);
    teardown =
      (fun () ->
        List.iter (stop_root runtime) !roots;
        roots := []);
  }

let workloads runtime =
  [
    Bench_common.workload "scalar.changed" (fun () ->
        scalar_workload runtime ~equal_model:false);
    Bench_common.workload "scalar.equal" (fun () ->
        scalar_workload runtime ~equal_model:true);
    Bench_common.workload "assoc.changed.1000" (fun () ->
        assoc_workload runtime 1_000);
    Bench_common.workload "assoc.changed.10000" (fun () ->
        assoc_workload runtime 10_000);
    Bench_common.workload "startup.root" (fun () ->
        startup_workload runtime);
  ]

let () =
  Eio_main.run @@ fun environment ->
  Eio.Switch.run @@ fun switch ->
  let runtime =
    Eta_eio.Runtime.create ~sw:switch
      ~clock:(Eio.Stdenv.clock environment) ()
  in
  Bench_common.main ~framework:"eta_crux" (workloads runtime)
