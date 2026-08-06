module C = Selected_core

exception Injected

let failf format = Printf.ksprintf failwith format
let int label expected actual =
  if expected <> actual then failf "%s: expected %d, got %d" label expected actual
let bool label expected actual =
  if expected <> actual then failf "%s: expected %b, got %b" label expected actual

let ok = function
  | Ok result -> result
  | Error C.Reentrant_stabilization -> failwith "unexpected reentry"
  | Error (C.Defect exn) -> raise exn

let defect = function
  | Error (C.Defect _) -> ()
  | Error C.Reentrant_stabilization -> failwith "wrong failure"
  | Ok _ -> failwith "expected failure"

let heterogenous_and_rollback () =
  let graph = C.create () in
  let source = C.var graph 1 in
  let text = C.map string_of_int (C.watch source) in
  let record = C.map (fun text -> ref text) text in
  let armed = ref false in
  let output =
    C.map (fun value -> if !armed then raise Injected else value) record
  in
  ignore (C.demand output);
  ignore (ok (C.stabilize graph));
  let old_text = C.value text in
  let old_record = C.value record in
  armed := true;
  C.set graph source 2;
  defect (C.stabilize graph);
  int "source rollback" 1 (C.value (C.watch source));
  bool "string physical rollback" true (C.value text == old_text);
  bool "record physical rollback" true (C.value record == old_record);
  armed := false;
  ignore (ok (C.stabilize graph));
  int "heterogeneous retry" 2 (int_of_string (C.value text));
  int "first-write journal" 4 (C.journal_high_water graph)

let static_work_and_verdict () =
  let graph = C.create () in
  let source = C.var graph 0 in
  let rec chain n value =
    if n = 0 then value else chain (n - 1) (C.map (( + ) 1) value)
  in
  let output = chain 10 (C.watch source) in
  let _ballast = Array.init 10_000 (fun i -> C.const graph i) in
  ignore (C.demand output);
  ignore (ok (C.stabilize graph));
  C.reset_work graph;
  C.set graph source 1;
  ignore (ok (C.stabilize graph));
  let work = C.work graph in
  int "affected claims" 11 work.claims;
  int "affected evaluations" 10 work.evaluations;
  int "affected dependency edges" 10 work.dependency_edges;
  int "static topology edits" 0 work.topology_edits;
  int "static cleanup" 0 work.cleanup_visits;
  int "constant verdict" 3 work.verdict_steps

let bind_rollback_cleanup () =
  let graph = C.create () in
  let source = C.var graph false in
  let owner =
    C.bind_owner (C.watch source) ~f:(fun selected ->
        C.map (fun x -> if selected then x + 10 else x) (C.const graph 1))
  in
  ignore (C.demand owner.bind_signal);
  ignore (ok (C.stabilize graph));
  let old = C.bind_current owner in
  C.set graph source true;
  defect (C.stabilize ~checkpoint:(fun () -> raise Injected) graph);
  bool "bind identity rollback" true (C.bind_current owner == old);
  bool "bind old scope rollback" true (C.validate_handle old);
  (match C.stabilize graph with
  | Ok _ -> ()
  | Error C.Reentrant_stabilization -> failwith "bind retry reentrant"
  | Error (C.Defect exn) ->
      failf "bind retry defect: %s" (Printexc.to_string exn));
  bool "bind identity switch" false (C.bind_current owner == old);
  bool "bind old scope cleanup" false (C.validate_handle old);
  int "bind value" 11 (C.value owner.bind_signal)

module IM = Map.Make (Int)

let input_ops =
  let iter_diff left right f =
    IM.merge
      (fun key left right ->
        (match left, right with
        | Some a, Some b when a <> b -> f key (C.Changed (a, b))
        | Some a, None -> f key (C.Left a)
        | None, Some b -> f key (C.Right b)
        | Some _, Some _ | None, None -> ());
        None)
      left right
    |> ignore
  in
  C.{ empty_input = IM.empty; compare_key = Int.compare; iter_diff }

let output_ops =
  C.
    {
      empty_output = IM.empty;
      set_output = (fun key value map -> IM.add key value map);
      remove_output = (fun key map -> IM.remove key map);
    }

let keyed_checks () =
  let graph = C.create () in
  let initial = IM.(empty |> add 1 10 |> add 2 20) in
  let source = C.var graph initial in
  let owner =
    C.keyed_owner ~input:(C.watch source) ~input_ops ~output_ops
      ~build:(fun ~key ~data -> C.map (fun value -> key + value) data) ()
  in
  ignore (C.demand owner.keyed_signal);
  ignore (ok (C.stabilize graph));
  let retained = Option.get (C.keyed_child owner 1) in
  let removed = Option.get (C.keyed_child owner 2) in
  C.set graph source IM.(empty |> add 1 11 |> add 3 30);
  defect (C.stabilize ~checkpoint:(fun () -> raise Injected) graph);
  bool "keyed retained rollback" true
    (Option.get (C.keyed_child owner 1) == retained);
  bool "keyed removed rollback" true
    (Option.get (C.keyed_child owner 2) == removed);
  bool "keyed removed scope rollback" true (C.keyed_scope_valid removed);
  ignore (ok (C.stabilize graph));
  bool "keyed retained identity" true
    (Option.get (C.keyed_child owner 1) == retained);
  bool "keyed removal cleanup" false (C.keyed_scope_valid removed);
  let replacement = Option.get (C.keyed_child owner 3) in
  bool "keyed addition valid" true (C.keyed_scope_valid replacement);
  C.set graph source IM.(empty |> add 1 11 |> add 2 22);
  ignore (ok (C.stabilize graph));
  let reentered = Option.get (C.keyed_child owner 2) in
  bool "keyed reentry identity" false (reentered == removed);
  bool "keyed stale handle" false (C.validate_handle removed.output);
  int "keyed output" 24 (IM.find 2 (C.value owner.keyed_signal))

let slot_reuse_quarantine () =
  let graph = C.create () in
  let old = C.const graph 1 in
  let old_handle = C.handle old in
  C.begin_pass graph;
  C.retire old;
  let fresh = C.const graph 2 in
  bool "same-pass quarantine" false
    (old_handle.slot = (C.handle fresh).slot);
  C.rollback graph;
  bool "retirement rollback" true (C.validate_handle old);
  bool "tentative stale" false (C.validate_handle fresh);
  C.begin_pass graph;
  C.retire old;
  C.commit graph;
  C.cleanup graph;
  let replacement = C.const graph 3 in
  int "free slot reuse" old_handle.slot (C.handle replacement).slot;
  bool "generation stale" false (C.validate_handle old);
  bool "replacement valid" true (C.validate_handle replacement)

let allocated_words operations run =
  run 20;
  Gc.full_major ();
  let before_minor, before_promoted, before_major = Gc.counters () in
  run operations;
  let after_minor, after_promoted, after_major = Gc.counters () in
  ((after_minor -. before_minor)
   +. (after_major -. before_major)
   -. (after_promoted -. before_promoted))
  /. float_of_int operations

type tracked_input = {
  values : int IM.t;
  delta : (int * int C.change) option;
}

type dag_node = Dag_source | Dag_map of int * int | Dag_map2 of int * int

let tracked_input_ops =
  let iter_diff left right f =
    match right.delta with
    | Some (key, change) -> f key change
    | None when IM.is_empty left.values ->
        IM.iter (fun key value -> f key (C.Right value)) right.values
    | None -> ()
  in
  C.
    {
      empty_input = { values = IM.empty; delta = None };
      compare_key = Int.compare;
      iter_diff;
    }

let allocation_and_economics () =
  List.iter
    (fun depth ->
      let workload = C.raw_scalar depth in
      let words = allocated_words 10_000 workload.run_batch in
      if words > 4.01 then
        failf "static depth %d allocated %.3f words" depth words)
    [ 1; 10; 100 ];

  let graph = C.create () in
  let source = C.var graph false in
  let selected =
    C.bind (C.watch source) ~f:(fun active ->
        C.const graph (if active then 1 else 0))
  in
  ignore (C.demand selected);
  C.stabilize_unit graph;
  let active = ref false in
  let run_dynamic operations =
    for _ = 1 to operations do
      active := not !active;
      C.set graph source !active;
      C.stabilize_unit graph
    done
  in
  let dynamic_words = allocated_words 10_000 run_dynamic in
  if dynamic_words > 51.6 then
    failf "dynamic switch allocated %.3f words" dynamic_words;

  let make_keyed size =
    let initial =
      let map = ref IM.empty in
      for key = 0 to size - 1 do
        map := IM.add key 0 !map
      done;
      !map
    in
    let graph = C.create () in
    let initial = { values = initial; delta = None } in
    let source = C.var graph initial in
    let owner =
      C.keyed_owner ~input:(C.watch source) ~input_ops:tracked_input_ops
        ~output_ops
        ~build:(fun ~key:_ ~data -> C.map Fun.id data) ()
    in
    ignore (C.demand owner.keyed_signal);
    C.stabilize_unit graph;
    graph, source, owner, ref initial
  in
  let measure_data size =
    let graph, source, owner, current = make_keyed size in
    let key = size / 2 in
    let next = ref 0 in
    let run operations =
      for _ = 1 to operations do
        next := 1 - !next;
        let previous = IM.find key (!current).values in
        current :=
          {
            values = IM.add key !next (!current).values;
            delta = Some (key, C.Changed (previous, !next));
          };
        C.set graph source !current;
        C.stabilize_unit graph
      done
    in
    let words = allocated_words 1_000 run in
    C.reset_work graph;
    run 1;
    let work = C.work graph in
    if work.claims > 5 || work.cleanup_visits > 3 then
      failf "keyed data size %d touched claims=%d cleanup=%d" size
        work.claims work.cleanup_visits;
    ignore owner;
    words
  in
  let measure_child size =
    let graph, _source, owner, _current = make_keyed size in
    let child = Option.get (C.keyed_child owner (size / 2)) in
    let next = ref 0 in
    let run operations =
      for _ = 1 to operations do
        next := 1 - !next;
        C.set graph child.data !next;
        C.stabilize_unit graph
      done
    in
    let words = allocated_words 1_000 run in
    C.reset_work graph;
    run 1;
    let work = C.work graph in
    if work.claims > 3 || work.topology_edits <> 0 then
      failf "keyed child size %d touched claims=%d topology=%d" size
        work.claims work.topology_edits;
    words
  in
  let measure_membership size =
    let graph, source, _owner, current = make_keyed size in
    let key = size in
    let present = ref false in
    let run operations =
      for _ = 1 to operations do
        present := not !present;
        current :=
          if !present then
            {
              values = IM.add key 1 (!current).values;
              delta = Some (key, C.Right 1);
            }
          else
            {
              values = IM.remove key (!current).values;
              delta = Some (key, C.Left 1);
            };
        C.set graph source !current;
        C.stabilize_unit graph
      done
    in
    allocated_words 1_000 run
  in
  let data_small = measure_data 1_000 in
  let data_large = measure_data 10_000 in
  let child_small = measure_child 1_000 in
  let child_large = measure_child 10_000 in
  let membership_small = measure_membership 1_000 in
  let membership_large = measure_membership 10_000 in
  if data_large > (data_small *. 3.) +. 100. then
    failf "keyed data scaled with live set: %.1f -> %.1f"
      data_small data_large;
  if child_large > (child_small *. 3.) +. 100. then
    failf "keyed child scaled with live set: %.1f -> %.1f"
      child_small child_large;
  if membership_large > (membership_small *. 3.) +. 100. then
    failf "keyed membership scaled with live set: %.1f -> %.1f"
      membership_small membership_large;
  Printf.printf
    "alloc words/op: dynamic=%.1f data=%.1f/%.1f child=%.1f/%.1f \
     membership=%.1f/%.1f\n%!"
    dynamic_words data_small data_large child_small child_large
    membership_small membership_large

let weak_root_reclamation () =
  let graph = C.create () in
  let source = C.var graph 1 in
  let live = C.map (( + ) 1) (C.watch source) in
  let live_demand = C.demand live in
  C.stabilize_unit graph;
  C.release live_demand;
  Gc.full_major ();
  C.release_unreachable_roots graph;
  bool "held unnecessary root remains live" true (C.validate_handle live);
  let dead_handle =
    let make_unreachable () =
      let root = C.map (( + ) 2) (C.watch source) in
      let demand = C.demand root in
      C.stabilize_unit graph;
      C.release demand;
      C.handle root
    in
    make_unreachable ()
  in
  Gc.full_major ();
  Gc.compact ();
  C.release_unreachable_roots graph;
  bool "held root survives unrelated reclamation" true
    (C.validate_handle live);
  bool "unreachable root reclaimed" false
    (C.handle_is_live graph dead_handle);
  int "reclamation tombstone" 1 (C.tombstone_count graph);
  let replacement = C.const graph 9 in
  int "reclaimed slot reused" dead_handle.slot (C.handle replacement).slot;
  bool "reclaimed generation stale" false
    (C.handle_is_live graph dead_handle);
  bool "source remains live" true (C.validate_handle (C.watch source))

let randomized_dags () =
  for seed = 0 to 31 do
    let random = Random.State.make [| seed; seed lxor 0x5a5a |] in
    let graph = C.create () in
    let sources = Array.init 8 (fun index -> C.var graph index) in
    let nodes = ref (Array.map C.watch sources) in
    let model = ref (Array.init 8 Fun.id) in
    let descriptions = ref (Array.make 8 Dag_source) in
    for _ = 1 to 64 do
      let available = Array.length !nodes in
      if Random.State.bool random then (
        let child = Random.State.int random available in
        let delta = 1 + Random.State.int random 7 in
        nodes := Array.append !nodes [| C.map (( + ) delta) (!nodes).(child) |];
        model := Array.append !model [| (!model).(child) + delta |];
        descriptions :=
          Array.append !descriptions [| Dag_map (child, delta) |])
      else (
        let left = Random.State.int random available in
        let right = Random.State.int random available in
        nodes :=
          Array.append !nodes
            [| C.map2 ( + ) (!nodes).(left) (!nodes).(right) |];
        model :=
          Array.append !model [| (!model).(left) + (!model).(right) |];
        descriptions :=
          Array.append !descriptions [| Dag_map2 (left, right) |])
    done;
    let output = (!nodes).(Array.length !nodes - 1) in
    let demand = C.demand output in
    C.stabilize_unit graph;
    int "random DAG initial" (!model).(Array.length !model - 1)
      (C.value output);
    for step = 1 to 40 do
      let source = Random.State.int random (Array.length sources) in
      let next = (seed * 1000) + step in
      C.set graph sources.(source) next;
      (!model).(source) <- next;
      for index = Array.length sources to Array.length !nodes - 1 do
        (!model).(index) <-
          (match (!descriptions).(index) with
          | Dag_source -> assert false
          | Dag_map (child, delta) -> (!model).(child) + delta
          | Dag_map2 (left, right) ->
              (!model).(left) + (!model).(right))
      done;
      C.stabilize_unit graph;
      int "random DAG stabilized"
        (!model).(Array.length !model - 1) (C.value output)
    done;
    C.release demand
  done

let () =
  Printf.printf "heterogeneous\n%!";
  heterogenous_and_rollback ();
  Printf.printf "static\n%!";
  static_work_and_verdict ();
  Printf.printf "bind\n%!";
  bind_rollback_cleanup ();
  Printf.printf "keyed\n%!";
  keyed_checks ();
  Printf.printf "slots\n%!";
  slot_reuse_quarantine ();
  Printf.printf "allocation/economics\n%!";
  allocation_and_economics ();
  Printf.printf "weak roots\n%!";
  weak_root_reclamation ();
  Printf.printf "random DAGs\n%!";
  randomized_dags ();
  Printf.printf "selected_core checks passed\n%!"
