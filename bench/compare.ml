type measurement = {
  name : string;
  metric : string;
  mean : float;
  median : float;
  has_median : bool;
  unit_ : string;
}

let usage () =
  prerr_endline
    "usage: dune exec bench/compare.exe -- [<left.json> <right.json>]\n\
     \       dune exec bench/compare.exe -- --gate \
     <left1.json> <right1.json> <left2.json> <right2.json> \
     <left3.json> <right3.json>";
  exit 2

let default_results_dir = "bench/results"

let latest_two_results () =
  let files =
    Sys.readdir default_results_dir |> Array.to_list
    |> List.filter (fun file -> Filename.check_suffix file ".json")
    |> List.sort String.compare
    |> List.map (Filename.concat default_results_dir)
  in
  match List.rev files with
  | right :: left :: _ -> (left, right)
  | _ ->
      prerr_endline
        ("bench/compare: need at least two .json files in " ^ default_results_dir);
      usage ()

let load path =
  let json = Yojson.Safe.from_file path in
  let open Yojson.Safe.Util in
  json |> member "benchmarks" |> to_list
  |> List.map (fun item ->
         {
           name = item |> member "name" |> to_string;
           metric = item |> member "metric" |> to_string;
           mean = item |> member "mean" |> to_float;
           median =
             (match item |> member "median" with
             | `Null -> item |> member "mean" |> to_float
             | value -> to_float value);
           has_median =
             (match item |> member "median" with
             | `Null -> false
             | _ -> true);
           unit_ = item |> member "unit" |> to_string;
         })

let key m = m.name ^ "|" ^ m.metric

let table xs =
  let tbl = Hashtbl.create (List.length xs) in
  List.iter (fun m -> Hashtbl.replace tbl (key m) m) xs;
  tbl

let unique values =
  let seen = Hashtbl.create (List.length values) in
  List.filter
    (fun value ->
      if Hashtbl.mem seen value then false
      else (
        Hashtbl.add seen value ();
        true))
    values

let machine_fingerprint path =
  let rec canonical (json : Yojson.Safe.t) : Yojson.Safe.t =
    match json with
    | `Assoc fields ->
        `Assoc
          (fields
          |> List.map (fun (name, value) -> (name, canonical value))
          |> List.sort (fun (left, _) (right, _) -> String.compare left right))
    | `List values -> `List (List.map canonical values)
    | `Tuple values -> `Tuple (List.map canonical values)
    | `Variant (name, value) -> `Variant (name, Option.map canonical value)
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _) as value ->
        value
  in
  let json = Yojson.Safe.from_file path in
  let open Yojson.Safe.Util in
  json |> member "machine" |> canonical |> Yojson.Safe.to_string

let rows_only left right =
  let right_keys = Hashtbl.create (List.length right) in
  List.iter (fun measurement -> Hashtbl.replace right_keys (key measurement) ())
    right;
  left |> List.map key |> unique
  |> List.filter (fun row_key -> not (Hashtbl.mem right_keys row_key))

let print_row_differences only_left only_right =
  Printf.printf "\nrows only in left (%d):\n" (List.length only_left);
  List.iter (fun row_key -> Printf.printf "  %s\n" row_key) only_left;
  Printf.printf "rows only in right (%d):\n" (List.length only_right);
  List.iter (fun row_key -> Printf.printf "  %s\n" row_key) only_right

let compare left right =
  let left_values = load left in
  let left_tbl = table left_values in
  let right_values = load right in
  let only_left = rows_only left_values right_values in
  let only_right = rows_only right_values left_values in
  Printf.printf "left:  %s\nright: %s\n\n" left right;
  let name_width =
    List.fold_left (fun width m -> max width (String.length m.name)) 54
      right_values
  in
  let metric_width =
    List.fold_left (fun width m -> max width (String.length m.metric)) 14
      right_values
  in
  Printf.printf "%-*s %-*s %14s %14s %12s\n" name_width "benchmark"
    metric_width "metric" "left median" "right median" "delta%";
  List.iter
    (fun r ->
      match Hashtbl.find_opt left_tbl (key r) with
      | None -> ()
      | Some l ->
          let delta =
            if l.median = 0. then 0.
            else
              ((r.median -. l.median) /. l.median)
              *. 100.
          in
          Printf.printf
            "%-*s %-*s %14.2f %14.2f %11.2f%% %s\n" name_width
            r.name metric_width r.metric l.median r.median delta
            r.unit_)
    right_values;
  print_row_differences only_left only_right;
  if only_left <> [] || only_right <> [] then
    Printf.eprintf
      "WARNING: benchmark row sets differ between %s and %s; deltas are \
       incomplete\n"
      left right;
  if machine_fingerprint left <> machine_fingerprint right then
    Printf.eprintf
      "WARNING: machine fingerprints differ (including profile) between %s \
       and %s; results may be incomparable\n"
      left right

let percent_increase ~before ~after =
  if before = 0. then
    if after = 0. then 0. else infinity
  else ((after -. before) /. before) *. 100.

let required_crux_rows =
  [
    "eta_crux.action.complete_advancement";
    "eta_crux.incremental.equal_model";
    "eta_crux.assoc.changed_child.10000";
    "eta_crux.assoc.changed_child.100000";
    "eta_crux.adapter.persistent_output.10000";
    "eta_crux.adapter.persistent_output.100000";
    "eta_crux.lifecycle.overlapping_cleanup";
    "eta_crux.driver.identity";
    "eta_crux.driver.serialized.0b";
    "eta_crux.driver.serialized.64b";
    "eta_crux.driver.serialized.4096b";
    "eta_crux.telemetry.disabled";
    "eta_crux.telemetry.absent_control";
    "eta_crux.observer.disabled";
    "eta_crux.reset.disabled";
    "eta_crux.poll.disabled";
    "eta_crux.capacity.ingress.1";
    "eta_crux.capacity.ingress.64";
    "eta_crux.capacity.ingress.1024";
    "eta_crux.capacity.request.1";
    "eta_crux.capacity.request.64";
    "eta_crux.capacity.request.1024";
    "eta_crux.capacity.serialized_handles";
  ]

let required_crux_keys =
  let measurements =
    List.concat_map
      (fun name ->
        [ name ^ "|wall_ns"; name ^ "|allocated_words" ])
      required_crux_rows
  in
  let counters =
    [
      "eta_crux.action.complete_advancement|counter.commits";
      "eta_crux.action.complete_advancement|counter.deliveries";
      "eta_crux.incremental.equal_model|counter.commits";
      "eta_crux.incremental.equal_model|counter.dependent_projections";
      "eta_crux.assoc.changed_child.10000|counter.child_visits";
      "eta_crux.assoc.changed_child.100000|counter.child_visits";
      "eta_crux.adapter.persistent_output.10000|counter.mutated_rows";
      "eta_crux.adapter.persistent_output.100000|counter.mutated_rows";
      "eta_crux.lifecycle.overlapping_cleanup|counter.new_starts";
      "eta_crux.lifecycle.overlapping_cleanup|counter.cleanup_releases";
      "eta_crux.driver.identity|counter.wire_operations";
      "eta_crux.driver.serialized.0b|counter.wire_operations";
      "eta_crux.driver.serialized.0b|counter.payload_bytes";
      "eta_crux.driver.serialized.64b|counter.wire_operations";
      "eta_crux.driver.serialized.64b|counter.payload_bytes";
      "eta_crux.driver.serialized.4096b|counter.wire_operations";
      "eta_crux.driver.serialized.4096b|counter.payload_bytes";
      "eta_crux.telemetry.disabled|counter.commits";
      "eta_crux.telemetry.absent_control|counter.commits";
      "eta_crux.observer.disabled|counter.commits";
      "eta_crux.reset.disabled|counter.commits";
      "eta_crux.poll.disabled|counter.commits";
      "eta_crux.capacity.ingress.1|counter.max_pending";
      "eta_crux.capacity.ingress.1|counter.admissions";
      "eta_crux.capacity.ingress.64|counter.max_pending";
      "eta_crux.capacity.ingress.64|counter.admissions";
      "eta_crux.capacity.ingress.1024|counter.max_pending";
      "eta_crux.capacity.ingress.1024|counter.admissions";
      "eta_crux.capacity.request.1|counter.max_pending";
      "eta_crux.capacity.request.1|counter.completions";
      "eta_crux.capacity.request.64|counter.max_pending";
      "eta_crux.capacity.request.64|counter.completions";
      "eta_crux.capacity.request.1024|counter.max_pending";
      "eta_crux.capacity.request.1024|counter.completions";
      "eta_crux.capacity.serialized_handles|counter.max_live_exports";
      "eta_crux.capacity.serialized_handles|counter.stale_handles";
      "eta_crux.capacity.serialized_handles|counter.collected_exports";
    ]
  in
  measurements @ counters

let expected_crux_counters =
  [
    "eta_crux.action.complete_advancement|counter.commits", 1.;
    "eta_crux.action.complete_advancement|counter.deliveries", 1.;
    "eta_crux.incremental.equal_model|counter.commits", 1.;
    "eta_crux.incremental.equal_model|counter.dependent_projections", 0.;
    "eta_crux.assoc.changed_child.10000|counter.child_visits", 1.;
    "eta_crux.assoc.changed_child.100000|counter.child_visits", 1.;
    "eta_crux.adapter.persistent_output.10000|counter.mutated_rows", 1.;
    "eta_crux.adapter.persistent_output.100000|counter.mutated_rows", 1.;
    "eta_crux.lifecycle.overlapping_cleanup|counter.new_starts", 1.;
    "eta_crux.lifecycle.overlapping_cleanup|counter.cleanup_releases", 1.;
    "eta_crux.driver.identity|counter.wire_operations", 0.;
    "eta_crux.driver.serialized.0b|counter.wire_operations", 2.;
    "eta_crux.driver.serialized.0b|counter.payload_bytes", 0.;
    "eta_crux.driver.serialized.64b|counter.wire_operations", 2.;
    "eta_crux.driver.serialized.64b|counter.payload_bytes", 64.;
    "eta_crux.driver.serialized.4096b|counter.wire_operations", 2.;
    "eta_crux.driver.serialized.4096b|counter.payload_bytes", 4_096.;
    "eta_crux.telemetry.disabled|counter.commits", 1.;
    "eta_crux.telemetry.absent_control|counter.commits", 1.;
    "eta_crux.observer.disabled|counter.commits", 1.;
    "eta_crux.reset.disabled|counter.commits", 1.;
    "eta_crux.poll.disabled|counter.commits", 1.;
    "eta_crux.capacity.ingress.1|counter.max_pending", 1.;
    "eta_crux.capacity.ingress.1|counter.admissions", 1.;
    "eta_crux.capacity.ingress.64|counter.max_pending", 64.;
    "eta_crux.capacity.ingress.64|counter.admissions", 64.;
    "eta_crux.capacity.ingress.1024|counter.max_pending", 1_024.;
    "eta_crux.capacity.ingress.1024|counter.admissions", 1_024.;
    "eta_crux.capacity.request.1|counter.max_pending", 1.;
    "eta_crux.capacity.request.1|counter.completions", 2.;
    "eta_crux.capacity.request.64|counter.max_pending", 64.;
    "eta_crux.capacity.request.64|counter.completions", 65.;
    "eta_crux.capacity.request.1024|counter.max_pending", 1_024.;
    "eta_crux.capacity.request.1024|counter.completions", 1_025.;
    "eta_crux.capacity.serialized_handles|counter.max_live_exports", 1.;
    "eta_crux.capacity.serialized_handles|counter.stale_handles", 1.;
    "eta_crux.capacity.serialized_handles|counter.collected_exports", 1.;
  ]

let gate pairs =
  let comparisons =
    List.map
      (fun (left, right) ->
        (left, right, table (load left), table (load right)))
      pairs
  in
  let keys = unique required_crux_keys in
  let failures = ref [] in
  let add_failure message = failures := message :: !failures in
  List.iter
    (fun measurement_key ->
      let regressions, complete =
        List.fold_left
          (fun (regressions, complete)
               (_, _, left, right) ->
            match
              Hashtbl.find_opt left measurement_key,
              Hashtbl.find_opt right measurement_key
            with
            | Some before, Some after
              when before.has_median && after.has_median ->
                let regressed =
                  match after.metric with
                  | "wall_ns" ->
                      percent_increase
                        ~before:before.median
                        ~after:after.median
                      > 15.
                  | "allocated_words" ->
                      after.median -. before.median > 1.
                      && percent_increase
                           ~before:before.median
                           ~after:after.median
                         > 5.
                  | _ -> false
                in
                ( regressions + Bool.to_int regressed,
                  complete + 1 )
            | Some _, Some _ | None, _ | _, None ->
                (regressions, complete))
          (0, 0) comparisons
      in
      if complete <> 3 then
        add_failure
          (Printf.sprintf
             "%s is missing from %d comparison(s)"
             measurement_key (3 - complete))
      else if regressions >= 2 then
        add_failure
          (Printf.sprintf
             "%s regressed in %d of 3 comparisons"
             measurement_key regressions))
    keys;
  let disabled_path_specs =
    [
      ( "post_commit_effect_observer_disabled_allocation",
        "eta_crux.observer.disabled" );
      ( "structural_reset_disabled_allocation",
        "eta_crux.reset.disabled" );
      ("poll_disabled_allocation", "eta_crux.poll.disabled");
    ]
  in
  List.iter
    (fun (gate_name, row_name) ->
      let regressions =
        List.fold_left
          (fun failures
               (left_path, right_path, left, right) ->
            let get table metric =
              Hashtbl.find_opt table (row_name ^ "|" ^ metric)
            in
            match
              get left "wall_ns",
              get right "wall_ns",
              get left "allocated_words",
              get right "allocated_words"
            with
            | Some before_wall, Some after_wall,
              Some before_words, Some after_words ->
                let failed =
                  before_words.median
                  <> after_words.median
                  || percent_increase
                       ~before:before_wall.median
                       ~after:after_wall.median
                     > 5.
                in
                failures + Bool.to_int failed
            | _ ->
                add_failure
                  (Printf.sprintf
                     "%s or %s has no complete %s row"
                     left_path right_path gate_name);
                failures)
          0 comparisons
      in
      if regressions >= 2 then
        add_failure
          (Printf.sprintf
             "%s failed in %d of 3 comparisons"
             gate_name regressions))
    disabled_path_specs;
  List.iter
    (fun (_, right_path, _, right) ->
      List.iter
        (fun (counter, expected) ->
          match Hashtbl.find_opt right counter with
          | Some measurement
            when measurement.has_median
                 && measurement.median = expected ->
              ()
          | Some measurement ->
              add_failure
                (Printf.sprintf
                   "%s reports %s=%g, expected %g"
                   right_path counter measurement.median
                   expected)
          | None -> ())
        expected_crux_counters)
    comparisons;
  List.iter
    (fun (left, right) -> compare left right)
    pairs;
  match List.rev !failures with
  | [] ->
      print_endline "\nbenchmark gate passed"
  | failures ->
      List.iter
        (fun failure ->
          Printf.eprintf "benchmark gate: %s\n" failure)
        failures;
      exit 1

let () =
  match Array.to_list Sys.argv with
  | [ _ ] ->
      let left, right = latest_two_results () in
      compare left right
  | [ _; left; right ] -> compare left right
  | [
   _;
   "--gate";
   left1;
   right1;
   left2;
   right2;
   left3;
   right3;
  ] ->
      gate
        [
          (left1, right1);
          (left2, right2);
          (left3, right3);
        ]
  | _ -> usage ()
