module Mutable_ref = Eta.Mutable_ref

module Signal = Eta_signal.Make (struct
  type t = |

  let pp _ppf (value : t) = match value with _ -> .
end) ()

let run_ok = function
  | Ok value -> value
  | Error error ->
      Format.eprintf "eta_signal bench failed: %a@." Signal.pp_graph_error
        (Obj.magic error);
      exit 1

let signal_static iterations =
  let source = Signal.Var.create 0 in
  let shared = Signal.Var.watch source |> Signal.map (fun n -> n + 1) in
  let left = Signal.map (fun n -> n * 2) shared in
  let right = Signal.map (fun n -> n * 3) shared in
  let total = Signal.map2 ( + ) left right in
  let observer =
    run_ok (Signal.Observer.observe total ~on_update:(fun _ -> Ok ()))
  in
  run_ok (Signal.stabilize ());
  for i = 1 to iterations do
    run_ok (Signal.Var.set source i);
    run_ok (Signal.stabilize ())
  done;
  ignore (run_ok (Signal.Observer.read observer) : int)

let mutable_ref_static iterations =
  let source = Mutable_ref.make 0 in
  let total = Mutable_ref.make 0 in
  for i = 1 to iterations do
    Mutable_ref.set source i;
    let shared = Mutable_ref.get source + 1 in
    let left = shared * 2 in
    let right = shared * 3 in
    Mutable_ref.set total (left + right)
  done;
  ignore (Mutable_ref.get total : int)

let signal_dynamic iterations =
  let choose_left = Signal.Var.create true in
  let left = Signal.Var.create 0 in
  let right = Signal.Var.create 0 in
  let selected =
    Signal.bind (Signal.Var.watch choose_left) ~f:(fun use_left ->
        if use_left then Signal.Var.watch left else Signal.Var.watch right)
    |> Signal.map (fun n -> n + 1)
  in
  let observer =
    run_ok (Signal.Observer.observe selected ~on_update:(fun _ -> Ok ()))
  in
  run_ok (Signal.stabilize ());
  for i = 1 to iterations do
    if i land 1 = 0 then (
      run_ok (Signal.Var.set choose_left true);
      run_ok (Signal.Var.set left i))
    else (
      run_ok (Signal.Var.set choose_left false);
      run_ok (Signal.Var.set right i));
    run_ok (Signal.stabilize ())
  done;
  ignore (run_ok (Signal.Observer.read observer) : int)

let mutable_ref_dynamic iterations =
  let choose_left = Mutable_ref.make true in
  let left = Mutable_ref.make 0 in
  let right = Mutable_ref.make 0 in
  let selected = Mutable_ref.make 0 in
  for i = 1 to iterations do
    if i land 1 = 0 then (
      Mutable_ref.set choose_left true;
      Mutable_ref.set left i)
    else (
      Mutable_ref.set choose_left false;
      Mutable_ref.set right i);
    let value =
      if Mutable_ref.get choose_left then Mutable_ref.get left
      else Mutable_ref.get right
    in
    Mutable_ref.set selected (value + 1)
  done;
  ignore (Mutable_ref.get selected : int)

let workloads =
  let item name run =
    Bench_lib.workload ("eta_signal." ^ name) run
  in
  [
    item "static.update_stabilize.10k" (fun () -> signal_static 10_000);
    item "static.mutable_ref.10k" (fun () -> mutable_ref_static 10_000);
    item "dynamic.bind_update_stabilize.10k" (fun () -> signal_dynamic 10_000);
    item "dynamic.mutable_ref.10k" (fun () -> mutable_ref_dynamic 10_000);
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
