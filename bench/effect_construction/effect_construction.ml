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

let workload samples name run =
  { Bench_lib.name = "effect.construction." ^ name; run; samples = Some samples }

let () =
  let opts = Bench_lib.parse_args () in
  let depth = if opts.quick then 10_000 else 100_000 in
  let samples = if opts.quick then 3 else 11 in
  let run build () =
    Construction_sink.consume (build depth (Effect.pure 0))
  in
  Bench_lib.run opts
    [
      workload samples "map_bind" (run build_map_bind);
      workload samples "preserve" (run build_preserve);
      workload samples "map_bind_preserve" (run build_mixed);
    ];
  Printf.eprintf "construction_sink=%d\n%!" (Construction_sink.fingerprint ())
