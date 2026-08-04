module Crux = Eta_crux

type workload = {
  name : string;
  run : unit -> unit;
  check : unit -> unit;
}

let failf format = Printf.ksprintf failwith format

let run_ok runtime effect =
  match Eta.Runtime.run runtime effect with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith (Eta.Cause.pretty (fun _ -> "typed failure") cause)

let start_post_commit runtime post_commit =
  ignore (run_ok runtime (Crux.Post_commit.start post_commit))

let unit_codec =
  Crux.Codec.make
    ~encode:(fun () -> Bytes.empty)
    ~decode:(fun _ -> Ok ())

let eta_chain machine depth =
  if depth < 1 then invalid_arg "chain depth must be positive";
  let first = Crux.map machine ~f:fst in
  let rec loop remaining signal =
    if remaining = 0 then signal
    else loop (remaining - 1) (Crux.map signal ~f:(( + ) 1))
  in
  loop (depth - 1) first

let make_eta_changed runtime depth =
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model ~action:() ->
        (model + 1, Eta.Effect.unit))
  in
  let endpoint =
    Crux.Exported_endpoint.create (Crux.map machine ~f:snd)
      ~codec:unit_codec
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      (Crux.both endpoint (eta_chain machine depth))
  in
  let export, initial_value, initial_post_commit =
    match Crux.Root.advance root with
    | Ok (Crux.Root.Committed { output = export, value; post_commit }) ->
        (export, value, post_commit)
    | Ok _
    | Error _ ->
        failwith "Eta Crux initial advance failed"
  in
  start_post_commit runtime initial_post_commit;
  let expected = ref 0 in
  let observed = ref initial_value in
  let run () =
    (match Crux.Exported_endpoint.try_invoke export () with
    | Ok (Ok (Ok ())) -> ()
    | Ok (Ok (Error Crux.Endpoint.Ingress_closed))
    | Ok (Error Crux.Exported_endpoint.Full)
    | Error _ ->
        failwith "Eta Crux action admission failed");
    match Crux.Root.advance root with
    | Ok (Crux.Root.Committed { output = _, value; post_commit }) ->
        start_post_commit runtime post_commit;
        incr expected;
        observed := value
    | Ok _
    | Error _ ->
        failwith "Eta Crux action advance failed"
  in
  let check () =
    let wanted = !expected + depth - 1 in
    if !observed <> wanted then
      failf "Eta Crux depth %d: expected %d, observed %d"
        depth wanted !observed
  in
  {
    name = Printf.sprintf "eta_crux.changed.depth_%d" depth;
    run;
    check;
  }

let make_eta_cutoff runtime depth =
  let dependent_visits = ref 0 in
  let machine =
    Crux.State_machine.create (Crux.return ())
      ~default_model:0
      ~apply_action:(fun ~self:_ ~input:() ~model:_ ~action:() ->
        (0, Eta.Effect.unit))
  in
  let endpoint =
    Crux.Exported_endpoint.create (Crux.map machine ~f:snd)
      ~codec:unit_codec
  in
  let constant = Crux.map machine ~f:(fun _ -> 0) in
  let rec depend remaining signal =
    if remaining = 0 then signal
    else
      depend (remaining - 1)
        (Crux.map signal ~f:(fun value ->
             incr dependent_visits;
             value + 1))
  in
  let output = depend depth constant in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      (Crux.both endpoint output)
  in
  let export, initial_value, initial_post_commit =
    match Crux.Root.advance root with
    | Ok (Crux.Root.Committed { output = export, value; post_commit }) ->
        (export, value, post_commit)
    | Ok _
    | Error _ ->
        failwith "Eta Crux cutoff initial advance failed"
  in
  start_post_commit runtime initial_post_commit;
  let initial_visits = !dependent_visits in
  let observed = ref initial_value in
  let run () =
    (match Crux.Exported_endpoint.try_invoke export () with
    | Ok (Ok (Ok ())) -> ()
    | Ok (Ok (Error Crux.Endpoint.Ingress_closed))
    | Ok (Error Crux.Exported_endpoint.Full)
    | Error _ ->
        failwith "Eta Crux cutoff action admission failed");
    match Crux.Root.advance root with
    | Ok (Crux.Root.Committed { output = _, value; post_commit }) ->
        start_post_commit runtime post_commit;
        observed := value
    | Ok _
    | Error _ ->
        failwith "Eta Crux cutoff advance failed"
  in
  let check () =
    if !observed <> depth then
      failf "Eta Crux cutoff output: expected %d, observed %d"
        depth !observed;
    if !dependent_visits <> initial_visits then
      failf "Eta Crux cutoff leaked to %d dependent nodes"
        (!dependent_visits - initial_visits)
  in
  {
    name = Printf.sprintf "eta_crux.cutoff.depth_%d" depth;
    run;
    check;
  }

let make_eta_dynamic runtime =
  let selector =
    Crux.State_machine.create (Crux.return ())
      ~default_model:false
      ~apply_action:(fun ~self:_ ~input:() ~model ~action:() ->
        (not model, Eta.Effect.unit))
  in
  let endpoint =
    Crux.Exported_endpoint.create (Crux.map selector ~f:snd)
      ~codec:unit_codec
  in
  let selected =
    Crux.bind (Crux.map selector ~f:fst) ~f:(fun active ->
        Crux.return (if active then 1 else 0))
  in
  let root =
    Crux.Root.create ~ingress_capacity:2 ~request_capacity:1
      (Crux.both endpoint selected)
  in
  let export, initial_value, initial_post_commit =
    match Crux.Root.advance root with
    | Ok (Crux.Root.Committed { output = export, value; post_commit }) ->
        (export, value, post_commit)
    | Ok _
    | Error _ ->
        failwith "Eta Crux dynamic initial advance failed"
  in
  start_post_commit runtime initial_post_commit;
  let expected = ref initial_value in
  let observed = ref initial_value in
  let run () =
    (match Crux.Exported_endpoint.try_invoke export () with
    | Ok (Ok (Ok ())) -> ()
    | Ok (Ok (Error Crux.Endpoint.Ingress_closed))
    | Ok (Error Crux.Exported_endpoint.Full)
    | Error _ ->
        failwith "Eta Crux dynamic action admission failed");
    match Crux.Root.advance root with
    | Ok (Crux.Root.Committed { output = _, value; post_commit }) ->
        start_post_commit runtime post_commit;
        expected := 1 - !expected;
        observed := value
    | Ok _
    | Error _ ->
        failwith "Eta Crux dynamic advance failed"
  in
  let check () =
    if !observed <> !expected then
      failf "Eta Crux dynamic: expected %d, observed %d"
        !expected !observed
  in
  {
    name = "eta_crux.dynamic.switch";
    run;
    check;
  }

let make_incremental_changed depth =
  if depth < 1 then invalid_arg "chain depth must be positive";
  let module Incr = Incremental.Make () in
  let variable = Incr.Var.create 0 in
  let rec chain remaining signal =
    if remaining = 0 then signal
    else chain (remaining - 1) (Incr.map signal ~f:(( + ) 1))
  in
  let output = chain depth (Incr.Var.watch variable) in
  let observer = Incr.observe output in
  Incr.stabilize ();
  let expected = ref 0 in
  let observed = ref (Incr.Observer.value_exn observer) in
  let run () =
    incr expected;
    Incr.Var.set variable !expected;
    Incr.stabilize ();
    observed := Incr.Observer.value_exn observer
  in
  let check () =
    let wanted = !expected + depth in
    if !observed <> wanted then
      failf "Incremental depth %d: expected %d, observed %d"
        depth wanted !observed
  in
  {
    name = Printf.sprintf "incremental.changed.depth_%d" depth;
    run;
    check;
  }

let make_incremental_cutoff depth =
  let module Incr = Incremental.Make () in
  let dependent_visits = ref 0 in
  let variable = Incr.Var.create 0 in
  let constant = Incr.map (Incr.Var.watch variable) ~f:(fun _ -> 0) in
  let rec depend remaining signal =
    if remaining = 0 then signal
    else
      depend (remaining - 1)
        (Incr.map signal ~f:(fun value ->
             incr dependent_visits;
             value + 1))
  in
  let output = depend depth constant in
  let observer = Incr.observe output in
  Incr.stabilize ();
  let initial_visits = !dependent_visits in
  let next = ref 0 in
  let observed = ref (Incr.Observer.value_exn observer) in
  let run () =
    incr next;
    Incr.Var.set variable !next;
    Incr.stabilize ();
    observed := Incr.Observer.value_exn observer
  in
  let check () =
    if !observed <> depth then
      failf "Incremental cutoff output: expected %d, observed %d"
        depth !observed;
    if !dependent_visits <> initial_visits then
      failf "Incremental cutoff leaked to %d dependent nodes"
        (!dependent_visits - initial_visits)
  in
  {
    name = Printf.sprintf "incremental.cutoff.depth_%d" depth;
    run;
    check;
  }

let make_incremental_dynamic () =
  let module Incr = Incremental.Make () in
  let selector = Incr.Var.create false in
  let selected =
    Incr.bind (Incr.Var.watch selector) ~f:(fun active ->
        Incr.return (if active then 1 else 0))
  in
  let observer = Incr.observe selected in
  Incr.stabilize ();
  let expected = ref 0 in
  let observed = ref (Incr.Observer.value_exn observer) in
  let run () =
    expected := 1 - !expected;
    Incr.Var.set selector (Bool.not (Incr.Var.value selector));
    Incr.stabilize ();
    observed := Incr.Observer.value_exn observer
  in
  let check () =
    if !observed <> !expected then
      failf "Incremental dynamic: expected %d, observed %d"
        !expected !observed
  in
  {
    name = "incremental.dynamic.switch";
    run;
    check;
  }

let repeat count f =
  for _ = 1 to count do
    f ()
  done

let elapsed f =
  let started = Unix.gettimeofday () in
  f ();
  Unix.gettimeofday () -. started

let rec calibrate workload operations =
  let seconds = elapsed (fun () -> repeat operations workload.run) in
  workload.check ();
  if seconds >= 0.5 || operations >= 16_777_216 then operations
  else calibrate workload (operations * 2)

let measure ~sample_count workload =
  let operations = calibrate workload 1 in
  repeat operations workload.run;
  workload.check ();
  Gc.full_major ();
  for sample = 1 to sample_count do
    let before_minor, before_promoted, before_major = Gc.counters () in
    let started = Unix.gettimeofday () in
    repeat operations workload.run;
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
  let rec loop only samples = function
    | [] -> only, samples
    | "--only" :: name :: rest -> loop (Some name) samples rest
    | "--samples" :: count :: rest ->
        loop only (int_of_string count) rest
    | arg :: _ -> invalid_arg ("unknown argument: " ^ arg)
  in
  loop None 21 (List.tl (Array.to_list Sys.argv))

let () =
  let only, sample_count = parse_args () in
  Eio_main.run @@ fun environment ->
  Eio.Switch.run @@ fun switch ->
  let runtime =
    Eta_eio.Runtime.create ~sw:switch
      ~clock:(Eio.Stdenv.clock environment) ()
  in
  let workloads =
    [
      make_incremental_changed 1;
      make_eta_changed runtime 1;
      make_incremental_changed 10;
      make_eta_changed runtime 10;
      make_incremental_changed 100;
      make_eta_changed runtime 100;
      make_incremental_cutoff 10;
      make_eta_cutoff runtime 10;
      make_incremental_dynamic ();
      make_eta_dynamic runtime;
    ]
  in
  let workloads =
    match only with
    | None -> workloads
    | Some name ->
        List.filter (fun workload -> String.equal workload.name name)
          workloads
  in
  if workloads = [] then invalid_arg "no workload matched --only";
  Printf.printf "name,operations,sample,wall_ns,allocated_words\n%!";
  List.iter (measure ~sample_count) workloads;
  exit 0
