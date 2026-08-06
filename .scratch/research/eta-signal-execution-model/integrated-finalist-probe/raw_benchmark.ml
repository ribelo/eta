module S = Selected_core
module Int_map = Map.Make (Int)

type t = S.workload

let name workload = workload.S.name
let run_batch workload count = workload.S.run_batch count
let final_read_and_check workload = workload.S.check ()

let dynamic () =
  let graph = S.create () in
  let source = S.var graph false in
  let output =
    S.bind (S.watch source) ~f:(fun active ->
        S.const graph (if active then 1 else 0))
  in
  ignore (S.demand output);
  let expected = ref 0 in
  {
    S.name = "dynamic.switch";
    run_batch =
      (fun count ->
        for _ = 1 to count do
          expected := 1 - !expected;
          S.set graph source (!expected <> 0);
          S.stabilize_unit graph
        done);
    check =
      (fun () ->
        if S.value output <> !expected then
          failwith "raw dynamic benchmark produced the wrong value");
  }

type tracked_input = {
  values : int Int_map.t;
  delta : (int * int S.change) option;
}

let input_ops =
  let iter_diff before after emit =
    match after.delta with
    | Some (key, change) -> emit key change
    | None when Int_map.is_empty before.values ->
        Int_map.iter (fun key value -> emit key (S.Right value)) after.values
    | None -> ()
  in
  S.
    {
      empty_input = { values = Int_map.empty; delta = None };
      compare_key = Int.compare;
      iter_diff;
    }

let output_ops =
  S.
    {
      empty_output = Int_map.empty;
      set_output = (fun key value map -> Int_map.add key value map);
      remove_output = (fun key map -> Int_map.remove key map);
    }

let initial_map size =
  let rec fill key map =
    if key = size then map else fill (key + 1) (Int_map.add key 0 map)
  in
  fill 0 Int_map.empty

let keyed_data size =
  let graph = S.create () in
  let current = ref { values = initial_map size; delta = None } in
  let source = S.var graph !current in
  let owner =
    S.keyed_owner ~input:(S.watch source) ~input_ops ~output_ops
      ~build:(fun ~key:_ ~data -> S.map (( + ) 1) data) ()
  in
  let output = owner.S.keyed_signal in
  ignore (S.demand output);
  let child = Option.get (S.keyed_child owner 0) in
  let expected = ref 0 in
  {
    S.name = Printf.sprintf "map.data_change.%d" size;
    run_batch =
      (fun count ->
        for _ = 1 to count do
          expected := 1 - !expected;
          let previous = Int_map.find 0 (!current).values in
          current :=
            {
              values = Int_map.add 0 !expected (!current).values;
              delta = Some (0, S.Changed (previous, !expected));
            };
          (* Admit the retained child source before the keyed owner runs. The
             tracked input still owns reconciliation and identity continuity. *)
          S.set graph child.data !expected;
          S.set graph source !current;
          S.stabilize_unit graph
        done);
    check =
      (fun () ->
        let observed = S.value output in
        if Int_map.cardinal observed <> size then
          failwith "raw keyed data benchmark changed cardinality";
        if Int_map.find_opt 0 observed <> Some (!expected + 1) then
          failwith "raw keyed data benchmark produced the wrong value");
  }

let keyed_membership size =
  let graph = S.create () in
  let current = ref { values = initial_map size; delta = None } in
  let source = S.var graph !current in
  let output =
    S.keyed ~input:(S.watch source) ~input_ops ~output_ops
      ~build:(fun ~key:_ ~data -> S.map (( + ) 1) data) ()
  in
  ignore (S.demand output);
  let present = ref false in
  {
    S.name = Printf.sprintf "map.membership_change.%d" size;
    run_batch =
      (fun count ->
        for _ = 1 to count do
          present := not !present;
          current :=
            if !present then
              {
                values = Int_map.add size 0 (!current).values;
                delta = Some (size, S.Right 0);
              }
            else
              {
                values = Int_map.remove size (!current).values;
                delta = Some (size, S.Left 0);
              };
          S.set graph source !current;
          S.stabilize_unit graph
        done);
    check =
      (fun () ->
        let observed = S.value output in
        let expected_cardinal = size + if !present then 1 else 0 in
        if Int_map.cardinal observed <> expected_cardinal then
          failwith "raw keyed membership benchmark changed cardinality";
        let expected = if !present then Some 1 else None in
        if Int_map.find_opt size observed <> expected then
          failwith "raw keyed membership benchmark produced the wrong value");
  }

let keyed_child size =
  let graph = S.create () in
  let input =
    S.var graph { values = initial_map size; delta = None }
  in
  let children = Array.init size (fun _ -> S.var graph 0) in
  let output =
    S.keyed ~input:(S.watch input) ~input_ops ~output_ops
      ~build:(fun ~key ~data ->
        S.map2 (fun _ child -> child) data (S.watch children.(key)))
      ()
  in
  ignore (S.demand output);
  let expected = ref 0 in
  let key = size / 2 in
  {
    S.name = Printf.sprintf "map.child_change.%d" size;
    run_batch =
      (fun count ->
        for _ = 1 to count do
          incr expected;
          S.set graph children.(key) !expected;
          S.stabilize_unit graph
        done);
    check =
      (fun () ->
        let observed = S.value output in
        if Int_map.cardinal observed <> size then
          failwith "raw keyed child benchmark changed cardinality";
        if Int_map.find_opt key observed <> Some !expected then
          failwith "raw keyed child benchmark produced the wrong value");
  }

let create = function
  | "changed.depth_1" -> S.raw_scalar 1
  | "changed.depth_10" -> S.raw_scalar 10
  | "changed.depth_100" -> S.raw_scalar 100
  | "cutoff.depth_10" -> S.raw_scalar ~cutoff:true 10
  | "dynamic.switch" -> dynamic ()
  | "map.data_change.10000" -> keyed_data 10_000
  | "map.data_change.100000" -> keyed_data 100_000
  | "map.membership_change.10000" -> keyed_membership 10_000
  | "map.membership_change.100000" -> keyed_membership 100_000
  | "map.child_change.10000" -> keyed_child 10_000
  | "map.child_change.100000" -> keyed_child 100_000
  | name -> invalid_arg ("unsupported raw finalist workload: " ^ name)
