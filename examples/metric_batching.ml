open Eta

type stats = {
  active : int;
  idle : int;
  waiting : int;
  max_size : int;
}

let require label condition =
  if not condition then failwith ("metric batching check failed: " ^ label)

let snapshot calls =
  incr calls;
  { active = 3; idle = 1; waiting = 2; max_size = 8 }

let gauge ?(unit_ = "{connection}") name value =
  Effect.metric ~name ~unit_ ~kind:Meter.gauge (Meter.number (Meter.Int value))

let metrics_of_stats stats =
  [
    gauge "example.pool.active" stats.active;
    gauge "example.pool.idle" stats.idle;
    gauge ~unit_:"{waiter}" "example.pool.waiting" stats.waiting;
    gauge "example.pool.max_size" stats.max_size;
  ]

let emit_pool_gauges ~snapshot ~builds =
  Effect.metric_updates_lazy (fun () ->
      incr builds;
      snapshot () |> metrics_of_stats)

let pp_error fmt = function _ -> Format.pp_print_string fmt "<error>"

let run_ok rt eff =
  match Eta_eio.Runtime.run rt eff with
  | Exit.Ok () -> ()
  | Exit.Error cause ->
      Format.eprintf "metric batching failed: %a@." (Cause.pp pp_error) cause;
      exit 1

let point_named name point =
  String.equal point.Meter.name name

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let disabled_builds = ref 0 in
  let disabled_snapshots = ref 0 in
  let disabled_rt = Eta_eio.Runtime.create ~sw ~clock () in
  run_ok disabled_rt
    (emit_pool_gauges
       ~snapshot:(fun () -> snapshot disabled_snapshots)
       ~builds:disabled_builds);
  require "disabled lazy thunk" (!disabled_builds = 0);
  require "disabled snapshot" (!disabled_snapshots = 0);

  let enabled_builds = ref 0 in
  let enabled_snapshots = ref 0 in
  let meter = Meter.in_memory () in
  let enabled_rt =
    Eta_eio.Runtime.create ~sw ~clock ~meter:(Meter.as_capability meter) ()
  in
  run_ok enabled_rt
    (emit_pool_gauges
       ~snapshot:(fun () -> snapshot enabled_snapshots)
       ~builds:enabled_builds);
  let points = Meter.dump meter in
  require "enabled lazy thunk" (!enabled_builds = 1);
  require "enabled snapshot" (!enabled_snapshots = 1);
  require "batched point count" (List.length points = 4);
  require "active point"
    (List.exists (point_named "example.pool.active") points);
  Format.printf "metric-batching:disabled_builds=%d enabled_points=%d active=%d@."
    !disabled_builds (List.length points) 3
