open Eta

type stats = {
  active : int;
  idle : int;
  waiting : int;
  max_size : int;
}

type error = [ `Unexpected ] [@@deriving eta_error]

let require label condition =
  if not condition then failwith ("metric batching check failed: " ^ label)

let snapshot calls =
  incr calls;
  { active = 3; idle = 1; waiting = 2; max_size = 8 }

let gauge ?(unit_ = "{connection}") name value =
  Eta_observability.metric ~name ~unit_ ~kind:Eta_observability.Meter.gauge (Eta_observability.Meter.number (Eta_observability.Meter.Int value))

let metrics_of_stats stats =
  [
    gauge "example.pool.active" stats.active;
    gauge "example.pool.idle" stats.idle;
    gauge ~unit_:"{waiter}" "example.pool.waiting" stats.waiting;
    gauge "example.pool.max_size" stats.max_size;
  ]

let emit_pool_gauges ~snapshot ~builds =
  Eta_observability.metric_updates_lazy (fun () ->
      incr builds;
      snapshot () |> metrics_of_stats)

let run_ok rt eff =
  match Eta_eio.Runtime.run rt eff with
  | Exit.Ok () -> ()
  | Exit.Error cause ->
      Format.eprintf "metric batching failed: %a@." (Cause.pp pp_error) cause;
      exit 1

let point_named name point =
  String.equal point.Eta_observability.Meter.name name

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
  let meter = Eta_observability.Meter.in_memory () in
  let enabled_rt =
    Eta_eio.Runtime.create ~sw ~clock ~meter:(Eta_observability.Meter.as_capability meter) ()
  in
  run_ok enabled_rt
    (emit_pool_gauges
       ~snapshot:(fun () -> snapshot enabled_snapshots)
       ~builds:enabled_builds);
  let points = Eta_observability.Meter.dump meter in
  require "enabled lazy thunk" (!enabled_builds = 1);
  require "enabled snapshot" (!enabled_snapshots = 1);
  require "batched point count" (List.length points = 4);
  require "active point"
    (List.exists (point_named "example.pool.active") points);
  Format.printf "metric-batching:disabled_builds=%d enabled_points=%d active=%d@."
    !disabled_builds (List.length points) 3
