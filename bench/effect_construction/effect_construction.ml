open Eta

let id value = value
let repure value = Effect.pure value
let effect_map = Sys.opaque_identity Effect.map
let effect_bind = Sys.opaque_identity Effect.bind
let effect_uninterruptible = Sys.opaque_identity Effect.uninterruptible

let rec build_map_bind remaining eff =
  if remaining = 0 then eff
  else
    eff
    |> effect_map id
    |> effect_bind repure
    |> build_map_bind (remaining - 1)

let rec build_preserve remaining eff =
  if remaining = 0 then eff
  else build_preserve (remaining - 1) (effect_uninterruptible eff)

let rec build_mixed remaining eff =
  if remaining = 0 then eff
  else
    eff
    |> effect_map id
    |> effect_bind repure
    |> effect_uninterruptible
    |> build_mixed (remaining - 1)

(* [ops] is the construction depth: one [run] call builds that many nodes. *)
let workload ~samples ~ops name run =
  Bench_lib.workload ~samples ~ops ("effect.construction." ^ name) run

let () =
  let opts = Bench_lib.parse_args () in
  let depth = if opts.quick then 10_000 else 100_000 in
  let samples = if opts.quick then 3 else 11 in
  let run build () =
    Construction_sink.consume (build depth (Effect.pure 0))
  in
  let workloads =
    [
      workload ~samples ~ops:depth "map_bind" (run build_map_bind);
      workload ~samples ~ops:depth "preserve" (run build_preserve);
      workload ~samples ~ops:depth "map_bind_preserve" (run build_mixed);
    ]
  in
  Bench_lib.run opts workloads;
  (* The sink is a dead-code fence: an empty sink after a workload ran means the
     optimizer deleted the construction being measured, which must fail loudly.
     An empty sink because [--filter] selected none of these rows is not a
     failure - asserting there aborted every filtered [bench/run.sh] invocation,
     including the bisect workflow the README documents. *)
  if List.exists (fun w -> Bench_lib.should_run opts w.Bench_lib.name) workloads
  then Printf.eprintf "construction_sink=%d\n%!" (Construction_sink.fingerprint ())
