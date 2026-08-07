module E = Eta.Effect

module Finalist = Selected_factory_fresh.Make (Eta_signal.No_observer_error) ()
module Signal = Finalist
module Signal_map = Eta_signal_map.Make (Signal.Package)

module Eta_order = struct
  type t = int

  let compare = Int.compare
end

module Eta_map = Eta_signal_map.Map.Make (Eta_order)
module Eta_keyed = Signal_map.Keyed (Eta_order)

type workload = {
  name : string;
  run_batch : int -> unit;
  check : unit -> unit;
}

type error = [ Signal.graph_error | Signal.observer_read_error | Signal.stabilize_error ]

let failf format = Printf.ksprintf failwith format

let widen (effect : ('a, [< error ]) E.t) : ('a, error) E.t =
  E.map_error (fun error -> (error :> error)) effect

let run_ok runtime effect =
  match Eta.Runtime.run runtime (widen effect) with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith (Eta.Cause.pretty (fun _ -> "typed failure") cause)

let observe_eta runtime signal =
  run_ok runtime
    (Signal.Observer.observe signal ~on_update:(fun _ -> Eta.Effect.unit))

let eta_step source next_value =
  E.bind
    (fun value ->
      E.bind (fun () -> Signal.stabilize) (Signal.Var.set source value))
    (E.sync next_value)

let run_eta_batch runtime step operations =
  let rec loop remaining =
    if remaining = 0 then E.unit
    else E.bind (fun () -> loop (remaining - 1)) step
  in
  run_ok runtime (loop operations)

let make_eta_changed runtime depth =
  let source = Signal.Var.create 0 in
  let rec chain remaining signal =
    if remaining = 0 then signal
    else chain (remaining - 1) (Signal.map (( + ) 1) signal)
  in
  let output = chain depth (Signal.Var.watch source) in
  let observer = observe_eta runtime output in
  run_ok runtime Signal.stabilize;
  let next = ref 0 in
  let step =
    eta_step source (fun () ->
        incr next;
        !next)
  in
  let read_observed () = run_ok runtime (Signal.Observer.read observer) in
  let observed = ref (read_observed ()) in
  let run_batch operations = run_eta_batch runtime step operations in
  let check () =
    observed := read_observed ();
    let expected = !next + depth in
    if !observed <> expected then
      failf "Finalist public depth %d: expected %d, observed %d"
        depth expected !observed
  in
  {
    name = Printf.sprintf "finalist.public.changed.depth_%d" depth;
    run_batch;
    check;
  }

let make_incremental_changed depth =
  let module Incr = Incremental.Make () in
  let source = Incr.Var.create 0 in
  let rec chain remaining signal =
    if remaining = 0 then signal
    else chain (remaining - 1) (Incr.map signal ~f:(( + ) 1))
  in
  let output = chain depth (Incr.Var.watch source) in
  let observer = Incr.observe output in
  Incr.Observer.on_update_exn observer ~f:(fun _ -> ());
  Incr.stabilize ();
  let next = ref 0 in
  let observed = ref (Incr.Observer.value_exn observer) in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Incr.Var.set source !next;
      Incr.stabilize ()
    done;
    observed := Incr.Observer.value_exn observer
  in
  let check () =
    let expected = !next + depth in
    if !observed <> expected then
      failf "Incremental depth %d: expected %d, observed %d"
        depth expected !observed
  in
  {
    name = Printf.sprintf "incremental.changed.depth_%d" depth;
    run_batch;
    check;
  }

let make_eta_cutoff runtime depth =
  let source = Signal.Var.create 0 in
  let constant = Signal.map (fun _ -> 0) (Signal.Var.watch source) in
  let rec depend remaining signal =
    if remaining = 0 then signal
    else depend (remaining - 1) (Signal.map (( + ) 1) signal)
  in
  let output = depend depth constant in
  let observer = observe_eta runtime output in
  run_ok runtime Signal.stabilize;
  let next = ref 0 in
  let step =
    eta_step source (fun () ->
        incr next;
        !next)
  in
  let read_observed () = run_ok runtime (Signal.Observer.read observer) in
  let observed = ref (read_observed ()) in
  let run_batch operations = run_eta_batch runtime step operations in
  let recomputes_before = (run_ok runtime (Signal.stats ())).recompute_count in
  run_batch 1;
  let recomputes_after = (run_ok runtime (Signal.stats ())).recompute_count in
  if recomputes_after - recomputes_before >= depth + 2 then
    failwith "Finalist public cutoff did not stop dependent recomputation";
  let check () =
    observed := read_observed ();
    if !observed <> depth then
      failf "Finalist public cutoff: expected %d, observed %d"
        depth !observed
  in
  {
    name = Printf.sprintf "finalist.public.cutoff.depth_%d" depth;
    run_batch;
    check;
  }

let make_incremental_cutoff depth =
  let module Incr = Incremental.Make () in
  let source = Incr.Var.create 0 in
  let constant = Incr.map (Incr.Var.watch source) ~f:(fun _ -> 0) in
  let rec depend remaining signal =
    if remaining = 0 then signal
    else depend (remaining - 1) (Incr.map signal ~f:(( + ) 1))
  in
  let output = depend depth constant in
  let observer = Incr.observe output in
  Incr.Observer.on_update_exn observer ~f:(fun _ -> ());
  Incr.stabilize ();
  let next = ref 0 in
  let observed = ref (Incr.Observer.value_exn observer) in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Incr.Var.set source !next;
      Incr.stabilize ()
    done;
    observed := Incr.Observer.value_exn observer
  in
  let recomputes_before =
    Incr.State.num_nodes_recomputed Incr.State.t
  in
  run_batch 1;
  let recomputes_after =
    Incr.State.num_nodes_recomputed Incr.State.t
  in
  if recomputes_after - recomputes_before >= depth + 2 then
    failwith "Incremental cutoff did not stop dependent recomputation";
  let check () =
    if !observed <> depth then
      failf "Incremental cutoff: expected %d, observed %d"
        depth !observed
  in
  {
    name = Printf.sprintf "incremental.cutoff.depth_%d" depth;
    run_batch;
    check;
  }

let make_eta_dynamic runtime =
  let selector = Signal.Var.create false in
  let selected =
    Signal.bind
      ~f:(fun active -> Signal.const (if active then 1 else 0))
      (Signal.Var.watch selector)
  in
  let observer = observe_eta runtime selected in
  run_ok runtime Signal.stabilize;
  let expected = ref 0 in
  let step =
    eta_step selector (fun () ->
        expected := 1 - !expected;
        !expected <> 0)
  in
  let read_observed () = run_ok runtime (Signal.Observer.read observer) in
  let observed = ref (read_observed ()) in
  let run_batch operations = run_eta_batch runtime step operations in
  let check () =
    observed := read_observed ();
    if !observed <> !expected then
      failf "Finalist public dynamic: expected %d, observed %d"
        !expected !observed
  in
  { name = "finalist.public.dynamic.switch"; run_batch; check }

let make_incremental_dynamic () =
  let module Incr = Incremental.Make () in
  let selector = Incr.Var.create false in
  let selected =
    Incr.bind (Incr.Var.watch selector) ~f:(fun active ->
        Incr.return (if active then 1 else 0))
  in
  let observer = Incr.observe selected in
  Incr.Observer.on_update_exn observer ~f:(fun _ -> ());
  Incr.stabilize ();
  let expected = ref 0 in
  let observed = ref (Incr.Observer.value_exn observer) in
  let run_batch operations =
    for _ = 1 to operations do
      expected := 1 - !expected;
      Incr.Var.set selector (!expected <> 0);
      Incr.stabilize ()
    done;
    observed := Incr.Observer.value_exn observer
  in
  let check () =
    if !observed <> !expected then
      failf "Incremental dynamic: expected %d, observed %d"
        !expected !observed
  in
  { name = "incremental.dynamic.switch"; run_batch; check }

let eta_base_map size =
  List.init size (fun key -> key, 0)
  |> Eta_map.of_list |> Result.get_ok

let core_base_map size =
  List.init size (fun key -> key, 0)
  |> Core.Map.of_alist_exn (module Core.Int)

let make_eta_keyed_data runtime size =
  let input = Signal.Var.create (eta_base_map size) in
  let output =
    Eta_keyed.mapi (Signal.Var.watch input) ~f:(fun ~key:_ ~data -> data)
  in
  let observer = observe_eta runtime output in
  run_ok runtime Signal.stabilize;
  let key = size / 2 in
  let current = ref (Signal.Var.value input) in
  let expected = ref 0 in
  let step =
    eta_step input (fun () ->
        expected := 1 - !expected;
        let next = Eta_map.set key !expected !current in
        current := next;
        next)
  in
  let read_observed () = run_ok runtime (Signal.Observer.read observer) in
  let observed = ref (read_observed ()) in
  let run_batch operations = run_eta_batch runtime step operations in
  let visits_before =
    (run_ok runtime (Signal.stats ())).keyed.child_visit_count
  in
  run_batch 1;
  let visits_after =
    (run_ok runtime (Signal.stats ())).keyed.child_visit_count
  in
  if visits_after - visits_before <> 1 then
    failwith "Finalist public Map data change did not visit exactly one child";
  let check () =
    observed := read_observed ();
    if Eta_map.cardinal !observed <> size then
      failwith "Finalist public Map changed cardinality";
    if Eta_map.find_opt key !observed <> Some !expected then
      failwith "Finalist public Map published the wrong keyed value"
  in
  {
    name = Printf.sprintf "finalist.public.map.data_change.%d" size;
    run_batch;
    check;
  }

let make_incr_map_data size =
  let module Incr = Incremental.Make () in
  let module IM = Incr_map.Make (Incr) in
  let input = Incr.Var.create (core_base_map size) in
  let output =
    IM.mapi' (Incr.Var.watch input) ~f:(fun ~key:_ ~data -> data)
  in
  let observer = Incr.observe output in
  Incr.Observer.on_update_exn observer ~f:(fun _ -> ());
  Incr.stabilize ();
  let key = size / 2 in
  let current = ref (Incr.Var.value input) in
  let expected = ref 0 in
  let observed = ref (Incr.Observer.value_exn observer) in
  let run_batch operations =
    for _ = 1 to operations do
      expected := 1 - !expected;
      let next = Core.Map.set !current ~key ~data:!expected in
      current := next;
      Incr.Var.set input next;
      Incr.stabilize ()
    done;
    observed := Incr.Observer.value_exn observer
  in
  let recomputes_before =
    Incr.State.num_nodes_recomputed Incr.State.t
  in
  run_batch 1;
  let recomputes_after =
    Incr.State.num_nodes_recomputed Incr.State.t
  in
  if recomputes_after - recomputes_before >= 32 then
    failwith "Incr_map data change recomputed too many nodes";
  let check () =
    if Core.Map.length !observed <> size then
      failwith "Incr_map changed cardinality";
    if Core.Map.find !observed key <> Some !expected then
      failwith "Incr_map published the wrong keyed value"
  in
  {
    name = Printf.sprintf "incr_map.data_change.%d" size;
    run_batch;
    check;
  }

let make_eta_keyed_membership runtime size =
  let input = Signal.Var.create (eta_base_map size) in
  let output =
    Eta_keyed.mapi (Signal.Var.watch input) ~f:(fun ~key:_ ~data -> data)
  in
  let observer = observe_eta runtime output in
  run_ok runtime Signal.stabilize;
  let key = size in
  let current = ref (Signal.Var.value input) in
  let present = ref false in
  let step =
    eta_step input (fun () ->
        present := not !present;
        let next =
          if !present then Eta_map.set key 1 !current
          else Eta_map.remove key !current
        in
        current := next;
        next)
  in
  let read_observed () = run_ok runtime (Signal.Observer.read observer) in
  let observed = ref (read_observed ()) in
  let run_batch operations = run_eta_batch runtime step operations in
  let check () =
    observed := read_observed ();
    let expected_cardinal = size + if !present then 1 else 0 in
    if Eta_map.cardinal !observed <> expected_cardinal then
      failwith "Finalist public Map membership changed cardinality incorrectly";
    let expected = if !present then Some 1 else None in
    if Eta_map.find_opt key !observed <> expected then
      failwith "Finalist public Map published the wrong membership"
  in
  {
    name = Printf.sprintf "finalist.public.map.membership_change.%d" size;
    run_batch;
    check;
  }

let make_incr_map_membership size =
  let module Incr = Incremental.Make () in
  let module IM = Incr_map.Make (Incr) in
  let input = Incr.Var.create (core_base_map size) in
  let output =
    IM.mapi' (Incr.Var.watch input) ~f:(fun ~key:_ ~data -> data)
  in
  let observer = Incr.observe output in
  Incr.Observer.on_update_exn observer ~f:(fun _ -> ());
  Incr.stabilize ();
  let key = size in
  let current = ref (Incr.Var.value input) in
  let present = ref false in
  let observed = ref (Incr.Observer.value_exn observer) in
  let run_batch operations =
    for _ = 1 to operations do
      present := not !present;
      let next =
        if !present then Core.Map.set !current ~key ~data:1
        else Core.Map.remove !current key
      in
      current := next;
      Incr.Var.set input next;
      Incr.stabilize ()
    done;
    observed := Incr.Observer.value_exn observer
  in
  let check () =
    let expected_length = size + if !present then 1 else 0 in
    if Core.Map.length !observed <> expected_length then
      failwith "Incr_map membership changed cardinality incorrectly";
    let expected = if !present then Some 1 else None in
    if Core.Map.find !observed key <> expected then
      failwith "Incr_map published the wrong membership"
  in
  {
    name = Printf.sprintf "incr_map.membership_change.%d" size;
    run_batch;
    check;
  }

let make_eta_keyed_child runtime size =
  let input = Signal.Var.create (eta_base_map size) in
  let children = Array.init size (fun _ -> Signal.Var.create 0) in
  let output =
    Eta_keyed.mapi (Signal.Var.watch input) ~f:(fun ~key ~data ->
        Signal.map2 (fun _ child -> child) data
          (Signal.Var.watch children.(key)))
  in
  let observer = observe_eta runtime output in
  run_ok runtime Signal.stabilize;
  let key = size / 2 in
  let expected = ref 0 in
  let step =
    eta_step children.(key) (fun () ->
        expected := 1 - !expected;
        !expected)
  in
  let read_observed () = run_ok runtime (Signal.Observer.read observer) in
  let observed = ref (read_observed ()) in
  let run_batch operations = run_eta_batch runtime step operations in
  let visits_before =
    (run_ok runtime (Signal.stats ())).keyed.child_visit_count
  in
  run_batch 1;
  let visits_after =
    (run_ok runtime (Signal.stats ())).keyed.child_visit_count
  in
  if visits_after - visits_before <> 1 then
    failwith "Finalist public Map child change did not visit exactly one child";
  let check () =
    observed := read_observed ();
    if Eta_map.cardinal !observed <> size then
      failwith "Finalist public Map child update changed cardinality";
    if Eta_map.find_opt key !observed <> Some !expected then
      failwith "Finalist public Map published the wrong child value"
  in
  {
    name = Printf.sprintf "finalist.public.map.child_change.%d" size;
    run_batch;
    check;
  }

let make_incr_map_child size =
  let module Incr = Incremental.Make () in
  let module IM = Incr_map.Make (Incr) in
  let input = Incr.Var.create (core_base_map size) in
  let children = Array.init size (fun _ -> Incr.Var.create 0) in
  let output =
    IM.mapi' (Incr.Var.watch input) ~f:(fun ~key ~data ->
        Incr.map2 data (Incr.Var.watch children.(key))
          ~f:(fun _ child -> child))
  in
  let observer = Incr.observe output in
  Incr.Observer.on_update_exn observer ~f:(fun _ -> ());
  Incr.stabilize ();
  let key = size / 2 in
  let expected = ref 0 in
  let observed = ref (Incr.Observer.value_exn observer) in
  let run_batch operations =
    for _ = 1 to operations do
      expected := 1 - !expected;
      Incr.Var.set children.(key) !expected;
      Incr.stabilize ()
    done;
    observed := Incr.Observer.value_exn observer
  in
  let recomputes_before =
    Incr.State.num_nodes_recomputed Incr.State.t
  in
  run_batch 1;
  let recomputes_after =
    Incr.State.num_nodes_recomputed Incr.State.t
  in
  if recomputes_after - recomputes_before >= 32 then
    failwith "Incr_map child change recomputed too many nodes";
  let check () =
    if Core.Map.length !observed <> size then
      failwith "Incr_map child update changed cardinality";
    if Core.Map.find !observed key <> Some !expected then
      failwith "Incr_map published the wrong child value"
  in
  {
    name = Printf.sprintf "incr_map.child_change.%d" size;
    run_batch;
    check;
  }

let elapsed f =
  let started = Unix.gettimeofday () in
  f ();
  Unix.gettimeofday () -. started

let rec calibrate workload operations =
  let seconds = elapsed (fun () -> workload.run_batch operations) in
  workload.check ();
  if seconds >= 0.5 || operations >= 16_777_216 then operations
  else calibrate workload (operations * 2)

let measure ~sample_count workload =
  let operations = calibrate workload 1 in
  workload.run_batch operations;
  workload.check ();
  Gc.full_major ();
  for sample = 1 to sample_count do
    let before_minor, before_promoted, before_major = Gc.counters () in
    let started = Unix.gettimeofday () in
    workload.run_batch operations;
    let stopped = Unix.gettimeofday () in
    let after_minor, after_promoted, after_major = Gc.counters () in
    workload.check ();
    let count = float_of_int operations in
    let wall_ns = ((stopped -. started) *. 1e9) /. count in
    let allocated_words =
      ((after_minor -. before_minor)
       +. (after_major -. before_major)
       -. (after_promoted -. before_promoted))
      /. count
    in
    Printf.printf "%s,%d,%d,%.6f,%.6f\n%!"
      workload.name operations sample wall_ns allocated_words
  done

let parse_args () =
  let rec loop only samples verify_only = function
    | [] -> only, samples, verify_only
    | "--only" :: name :: rest -> loop (Some name) samples verify_only rest
    | "--samples" :: count :: rest ->
        loop only (int_of_string count) verify_only rest
    | "--verify-only" :: rest -> loop only samples true rest
    | arg :: _ -> invalid_arg ("unknown argument: " ^ arg)
  in
  loop None 9 false (List.tl (Array.to_list Sys.argv))

let () =
  let only, sample_count, verify_only = parse_args () in
  let selected =
    match only with
    | Some selected -> selected
    | None ->
        invalid_arg
          "exactly one workload is required; use --only NAME so each workload \
           runs in a fresh process"
  in
  Eio_main.run @@ fun environment ->
  Eio.Switch.run @@ fun switch ->
  let runtime =
    Eta_eio.Runtime.create ~sw:switch
      ~clock:(Eio.Stdenv.clock environment) ()
  in
  let candidates =
    [
      "incremental.changed.depth_1", (fun () -> make_incremental_changed 1);
      "finalist.public.changed.depth_1", (fun () -> make_eta_changed runtime 1);
      "incremental.changed.depth_10", (fun () -> make_incremental_changed 10);
      "finalist.public.changed.depth_10", (fun () -> make_eta_changed runtime 10);
      "incremental.changed.depth_100", (fun () -> make_incremental_changed 100);
      "finalist.public.changed.depth_100", (fun () -> make_eta_changed runtime 100);
      "incremental.cutoff.depth_10", (fun () -> make_incremental_cutoff 10);
      "finalist.public.cutoff.depth_10", (fun () -> make_eta_cutoff runtime 10);
      "incremental.dynamic.switch", make_incremental_dynamic;
      "finalist.public.dynamic.switch", (fun () -> make_eta_dynamic runtime);
      "incr_map.data_change.10000", (fun () -> make_incr_map_data 10_000);
      "finalist.public.map.data_change.10000",
        (fun () -> make_eta_keyed_data runtime 10_000);
      "incr_map.data_change.100000", (fun () -> make_incr_map_data 100_000);
      "finalist.public.map.data_change.100000",
        (fun () -> make_eta_keyed_data runtime 100_000);
      "incr_map.membership_change.10000",
        (fun () -> make_incr_map_membership 10_000);
      "finalist.public.map.membership_change.10000",
        (fun () -> make_eta_keyed_membership runtime 10_000);
      "incr_map.membership_change.100000",
        (fun () -> make_incr_map_membership 100_000);
      "finalist.public.map.membership_change.100000",
        (fun () -> make_eta_keyed_membership runtime 100_000);
      "incr_map.child_change.10000", (fun () -> make_incr_map_child 10_000);
      "finalist.public.map.child_change.10000",
        (fun () -> make_eta_keyed_child runtime 10_000);
      "incr_map.child_change.100000", (fun () -> make_incr_map_child 100_000);
      "finalist.public.map.child_change.100000",
        (fun () -> make_eta_keyed_child runtime 100_000);
    ]
  in
  if verify_only then
    if List.exists (fun (name, _) -> String.equal selected name) candidates then (
      Printf.printf "matched: %s\n%!" selected;
      exit 0)
    else invalid_arg "no workload matched --only";
  let workloads =
    List.filter_map
      (fun (name, make) ->
        if not (String.equal selected name) then None
        else
            let workload = make () in
            if not (String.equal workload.name name) then
              failwith "workload name mismatch";
            Some workload)
      candidates
  in
  if workloads = [] then invalid_arg "no workload matched --only";
  Printf.printf "name,operations,sample,wall_ns,allocated_words\n%!";
  List.iter (measure ~sample_count) workloads;
  exit 0
