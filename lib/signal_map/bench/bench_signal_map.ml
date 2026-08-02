module E = Eta.Effect

(* Deterministic gate for [smperf-ngt2], [smperf-g70n], [smperf-siyo],
   [smperf-mc2c], [smperf-ssho], [smperf-3v0d], [smperf-mnvd], and
   [smperf-2vzo]. Wall time is evidence only. *)

module Counting_order = struct
  type t = int

  let comparisons = ref 0

  let compare left right =
    comparisons := !comparisons + 1;
    Int.compare left right

  let reset () = comparisons := 0
  let count () = !comparisons
end

module M = Eta_signal_map.Map.Make (Counting_order)
module S = Eta_signal_map.Make (Eta_signal.No_observer_error) ()
module K = S.Keyed (Counting_order)

type error = [ S.graph_error | S.observer_read_error | S.stabilize_error ]

type output = { output_id : int }

type payload = {
  version : int;
  output : output;
}

type edit =
  | Insert of int * payload
  | Remove of int
  | Change of int * payload

type workload =
  | Insertions
  | Removals
  | Data_changes
  | Mixed

type measurement = {
  comparisons : int;
  seconds : float;
}

let workloads = [ Insertions; Removals; Data_changes; Mixed ]
let sizes = [ 31; 127; 1_023; 16_383; 262_143; 1_000_000 ]
let edit_counts = [ 1; 8; 64 ]

let workload_name = function
  | Insertions -> "insertions"
  | Removals -> "removals"
  | Data_changes -> "data_changes"
  | Mixed -> "mixed"

let failf format = Printf.ksprintf failwith format

let widen (eff : ('a, [< error ]) E.t) : ('a, error) E.t =
  E.map_error (fun error -> (error :> error)) eff

let run_ok runtime eff =
  Eta_test.Expect.expect_ok (Eta.Runtime.run runtime (widen eff))

let measure run =
  Counting_order.reset ();
  let started = Unix.gettimeofday () in
  let result = run () in
  let stopped = Unix.gettimeofday () in
  result, { comparisons = Counting_order.count (); seconds = stopped -. started }

let check_equal label expected actual =
  if actual <> expected then failf "%s: expected %d, got %d" label expected actual

let check_le label actual limit =
  if actual > limit then failf "%s: %d exceeds %d" label actual limit

let check_ge label actual limit =
  if actual < limit then failf "%s: %d is below %d" label actual limit

let ceil_log2 value =
  let rec loop power bits =
    if power >= value then bits else loop (power * 2) (bits + 1)
  in
  loop 1 0

let positions n k =
  Array.init k (fun index -> ((index + 1) * n) / (k + 1))

let make_output key version =
  { output_id = 1_000_000_000 + (key * 17) + version }

let make_base n =
  List.init n (fun index ->
      let key = index * 2 in
      key, { version = 0; output = { output_id = key } })

let make_edits workload base k =
  Array.mapi
    (fun edit_index position ->
      let key, payload = base.(position) in
      match workload with
      | Insertions ->
          let key = key + 1 in
          Insert
            ( key,
              {
                version = edit_index + 1;
                output = make_output key (edit_index + 1);
              } )
      | Removals -> Remove key
      | Data_changes ->
          Change
            ( key,
              {
                version = edit_index + 1;
                output = make_output key (edit_index + 1);
              } )
      | Mixed ->
          (match edit_index mod 3 with
          | 0 ->
              let key = key + 1 in
              Insert
                ( key,
                  {
                    version = edit_index + 1;
                    output = make_output key (edit_index + 1);
                  } )
          | 1 -> Remove key
          | _ ->
              Change
                ( key,
                  {
                    version = edit_index + 1;
                    output = make_output key (edit_index + 1);
                  } )))
    (positions (Array.length base) k)

let edit_classes edits =
  Array.fold_left
    (fun (insertions, removals, changes) -> function
      | Insert _ -> insertions + 1, removals, changes
      | Remove _ -> insertions, removals + 1, changes
      | Change _ -> insertions, removals, changes + 1)
    (0, 0, 0) edits

let apply_edits edits map =
  Array.fold_left
    (fun map -> function
      | Insert (key, payload) | Change (key, payload) -> M.set key payload map
      | Remove key -> M.remove key map)
    map edits

let apply_output_edits edits map =
  Array.fold_left
    (fun map -> function
      | Insert (key, payload) | Change (key, payload) ->
          M.set key payload.output map
      | Remove key -> M.remove key map)
    map edits

let diff_events left right =
  M.fold_symmetric_diff left right ~init:0
    ~f:(fun count _key _change -> count + 1)

let full_ordered_merge left right =
  let rec loop events left right =
    match left, right with
    | [], [] -> events
    | _ :: left, [] -> loop (events + 1) left []
    | [], _ :: right -> loop (events + 1) [] right
    | ((left_key, left_data) :: left_tail as left),
      ((right_key, right_data) :: right_tail as right) ->
        let order = Counting_order.compare left_key right_key in
        if order = 0 then
          loop
            (if left_data == right_data then events else events + 1)
            left_tail right_tail
        else if order < 0 then loop (events + 1) left_tail right
        else loop (events + 1) left right_tail
  in
  loop 0 left right

let verify_map_physical label expected actual =
  let rec loop expected actual =
    match expected, actual with
    | [], [] -> ()
    | (expected_key, expected_data) :: expected,
      (actual_key, actual_data) :: actual
      when expected_key = actual_key && expected_data == actual_data ->
        loop expected actual
    | _ -> failf "%s: output map mismatch" label
  in
  loop (M.to_list expected) (M.to_list actual)

let emit_enabled = ref false

let emit ~section ~n ~k ~workload ~metric measurement ~events ~child_visits =
  if !emit_enabled then
    Printf.printf "%s,%d,%d,%s,%s,%d,%d,%d,%.9f\n%!" section n k
      (workload_name workload) metric measurement.comparisons events child_visits
      measurement.seconds

let gate_limits n k =
  let log = ceil_log2 (n + 1) + 1 in
  8 * k * log, 16 * k * log, max 1 (n - k)

let run_map_case ~n ~k ~workload base_array base independent_base output_base =
  let edits = make_edits workload base_array k in
  let changed = apply_edits edits base in
  let independent = apply_edits edits independent_base in
  let output_changed = apply_output_edits edits output_base in
  let bound_n = max (M.cardinal base) (M.cardinal changed) in
  let shared_events, shared = measure (fun () -> diff_events base changed) in
  let independent_events, independent_measurement =
    measure (fun () -> diff_events base independent)
  in
  let left_bindings = M.to_list base in
  let right_bindings = M.to_list independent in
  let merge_events, merge =
    measure (fun () -> full_ordered_merge left_bindings right_bindings)
  in
  let downstream_events, downstream =
    measure (fun () -> diff_events output_base output_changed)
  in
  check_equal "shared diff events" k shared_events;
  check_equal "independent diff events" k independent_events;
  check_equal "full merge events" k merge_events;
  check_equal "downstream diff events" k downstream_events;
  let shared_limit, _keyed_limit, linear_floor = gate_limits bound_n k in
  check_le "shared diff gate" shared.comparisons shared_limit;
  check_le "downstream diff gate" downstream.comparisons shared_limit;
  check_ge "independent diff control" independent_measurement.comparisons
    linear_floor;
  check_ge "full merge control" merge.comparisons linear_floor;
  if bound_n >= 262_143 then (
    check_le "shared/control separation" (shared.comparisons * 4)
      independent_measurement.comparisons;
    check_le "downstream/control separation" (downstream.comparisons * 4)
      merge.comparisons);
  emit ~section:"map" ~n ~k ~workload ~metric:"shared_diff" shared
    ~events:shared_events ~child_visits:0;
  emit ~section:"map" ~n ~k ~workload ~metric:"independent_diff"
    independent_measurement ~events:independent_events ~child_visits:0;
  emit ~section:"map" ~n ~k ~workload ~metric:"full_merge" merge
    ~events:merge_events ~child_visits:0;
  emit ~section:"map" ~n ~k ~workload ~metric:"downstream_diff" downstream
    ~events:downstream_events ~child_visits:0

let run_map_size n base_array base_list =
  let base = M.of_list base_list |> Result.get_ok in
  let independent_base = M.of_list base_list |> Result.get_ok in
  let output_base = M.map (fun payload -> payload.output) base in
  List.iter
    (fun k ->
      if k <= max 1 (n / 2) then
        List.iter
          (fun workload ->
            run_map_case ~n ~k ~workload base_array base independent_base
              output_base)
          workloads)
    edit_counts;
  base

let stats runtime = run_ok runtime (S.stats ())
let stabilize runtime = run_ok runtime S.stabilize
let set runtime source value = run_ok runtime (S.Var.set source value)
let read runtime observer = run_ok runtime (S.Observer.read observer)

let observe runtime signal =
  run_ok runtime (S.Observer.observe signal (fun _update -> E.unit))

let dispose runtime observer = run_ok runtime (S.Observer.dispose observer)

let run_keyed_case runtime ~n ~k ~workload base_array input observer base =
  let edits = make_edits workload base_array k in
  let insertions, _removals, changes = edit_classes edits in
  let changed = apply_edits edits base in
  let bound_n = max (M.cardinal base) (M.cardinal changed) in
  let output_before = read runtime observer in
  let before = (stats runtime).keyed in
  let (), reconciliation =
    measure (fun () ->
        set runtime input changed;
        stabilize runtime)
  in
  let output_after = read runtime observer in
  let after = (stats runtime).keyed in
  verify_map_physical "keyed reconciliation" changed output_after;
  check_equal "keyed reconciliation count" 1
    (after.reconciliation_count - before.reconciliation_count);
  check_equal "keyed diff events" k
    (after.input_diff_event_count - before.input_diff_event_count);
  check_equal "keyed child visits" (insertions + changes)
    (after.child_visit_count - before.child_visit_count);
  let downstream_events, downstream =
    measure (fun () -> diff_events output_before output_after)
  in
  check_equal "keyed downstream events" k downstream_events;
  let full_scan_visits, full_scan =
    measure (fun () ->
        M.fold (fun _ _ count -> count + 1) output_after 0)
  in
  let shared_limit, keyed_limit, linear_floor = gate_limits bound_n k in
  check_le "keyed reconciliation gate" reconciliation.comparisons keyed_limit;
  check_le "keyed downstream gate" downstream.comparisons shared_limit;
  check_ge "keyed full-scan control" full_scan_visits linear_floor;
  if bound_n >= 262_143 then
    check_le "keyed/full-scan separation" (reconciliation.comparisons * 4)
      full_scan_visits;
  emit ~section:"keyed" ~n ~k ~workload ~metric:"reconciliation"
    reconciliation ~events:k ~child_visits:(insertions + changes);
  emit ~section:"keyed" ~n ~k ~workload ~metric:"downstream_diff"
    downstream ~events:downstream_events ~child_visits:0;
  emit ~section:"keyed" ~n ~k ~workload ~metric:"full_scan_control" full_scan
    ~events:0 ~child_visits:full_scan_visits;
  set runtime input base;
  stabilize runtime

let run_keyed_input_size runtime n base_array base =
  let input = S.Var.create base in
  let output = K.mapi (S.Var.watch input) ~f:(fun ~key:_ ~data -> data) in
  let observer = observe runtime output in
  stabilize runtime;
  List.iter
    (fun k ->
      if k <= max 1 (n / 2) then
        List.iter
          (fun workload ->
            run_keyed_case runtime ~n ~k ~workload base_array input observer base)
          workloads)
    edit_counts;
  dispose runtime observer

let run_child_case runtime ~n ~c child_sources observer =
  let selected = positions n c in
  let output_before = read runtime observer in
  let before = (stats runtime).keyed in
  let (), reconciliation =
    measure (fun () ->
        Array.iter (fun index -> set runtime child_sources.(index) 1) selected;
        stabilize runtime)
  in
  let output_after = read runtime observer in
  let after = (stats runtime).keyed in
  check_equal "affected child visits" c
    (after.child_visit_count - before.child_visit_count);
  let downstream_events, downstream =
    measure (fun () -> diff_events output_before output_after)
  in
  check_equal "affected downstream events" c downstream_events;
  let shared_limit, keyed_limit, linear_floor = gate_limits n c in
  check_le "affected-child reconciliation gate" reconciliation.comparisons
    keyed_limit;
  check_le "affected-child downstream gate" downstream.comparisons shared_limit;
  let full_scan_visits = M.fold (fun _ _ count -> count + 1) output_before 0 in
  check_equal "full-scan child visits" n full_scan_visits;
  check_ge "full-scan child control" full_scan_visits linear_floor;
  if n >= 262_143 then
    check_le "affected/full-scan separation" (reconciliation.comparisons * 4)
      full_scan_visits;
  emit ~section:"child" ~n ~k:c ~workload:Data_changes
    ~metric:"affected_reconciliation" reconciliation ~events:0
    ~child_visits:c;
  emit ~section:"child" ~n ~k:c ~workload:Data_changes
    ~metric:"downstream_diff" downstream ~events:downstream_events
    ~child_visits:0;
  Array.iter (fun index -> set runtime child_sources.(index) 0) selected;
  stabilize runtime

let run_child_size runtime n base =
  let child_sources = Array.init n (fun _ -> S.Var.create 0) in
  let input = S.Var.create base in
  let output =
    K.mapi (S.Var.watch input) ~f:(fun ~key ~data:_ ->
        S.Var.watch child_sources.(key / 2))
  in
  let observer = observe runtime output in
  stabilize runtime;
  List.iter
    (fun c ->
      if c <= max 1 (n / 2) then
        run_child_case runtime ~n ~c child_sources observer)
    edit_counts;
  dispose runtime observer

let run ~max_size =
  if !emit_enabled then
    Printf.printf
      "section,n,k,workload,metric,key_comparisons,events,child_visits,seconds\n%!";
  Eta_test.with_test_clock @@ fun _switch _clock runtime ->
  List.iter
    (fun n ->
      if n <= max_size then (
        let base_list = make_base n in
        let base_array = Array.of_list base_list in
        let base = run_map_size n base_array base_list in
        run_keyed_input_size runtime n base_array base;
        Gc.full_major ();
        run_child_size runtime n base;
        Gc.full_major ()))
    sizes

let () =
  let max_size = ref 1_000_000 in
  let gate = ref false in
  let specs =
    [
      "--gate", Arg.Set gate, " enforce deterministic complexity ceilings";
      "--emit", Arg.Set emit_enabled, " emit wall-time evidence as CSV";
      "--max-size", Arg.Set_int max_size, "N largest map size";
    ]
  in
  Arg.parse specs
    (fun argument -> raise (Arg.Bad ("unexpected argument " ^ argument)))
    "eta-signal-map-complexity";
  if not !gate then raise (Arg.Bad "--gate is required");
  run ~max_size:!max_size
