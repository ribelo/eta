open Effet
open Services

module Env_row = struct
  module V1 = struct
    let leaf () =
      Effect.sync "env.v1.leaf" (fun env -> env#clock.now)

    let m1 () = leaf ()
    let m2 () = m1 ()
    let m3 () = m2 ()
    let top () = m3 ()
  end

  module V2 = struct
    let leaf () =
      Effect.sync "env.v2.leaf" (fun env ->
        record_metric env#metrics;
        env#clock.now)

    let m1 () = leaf ()
    let m2 () = m1 ()
    let m3 () = m2 ()
    let top () = m3 ()
  end
end

module Args = struct
  module V1 = struct
    let leaf ~clock = Effect.sync "args.v1.leaf" (fun _env -> clock.now)
    let m1 ~clock = leaf ~clock
    let m2 ~clock = m1 ~clock
    let m3 ~clock = m2 ~clock
    let top ~clock = m3 ~clock
  end

  module V2 = struct
    let leaf ~clock ~metrics =
      Effect.sync "args.v2.leaf" (fun _env ->
        record_metric metrics;
        clock.now)

    let m1 ~clock ~metrics = leaf ~clock ~metrics
    let m2 ~clock ~metrics = m1 ~clock ~metrics
    let m3 ~clock ~metrics = m2 ~clock ~metrics
    let top ~clock ~metrics = m3 ~clock ~metrics
  end
end

module Bag = struct
  class type services_v1 = object
    method clock : clock
  end

  class type services_v2 = object
    method clock : clock
    method metrics : metrics
  end

  module V1 = struct
    let leaf (services : #services_v1) =
      Effect.sync "bag.v1.leaf" (fun _env -> services#clock.now)

    let m1 services = leaf services
    let m2 services = m1 services
    let m3 services = m2 services
    let top services = m3 services
  end

  module V2 = struct
    let leaf (services : #services_v2) =
      Effect.sync "bag.v2.leaf" (fun _env ->
        record_metric services#metrics;
        services#clock.now)

    let m1 services = leaf services
    let m2 services = m1 services
    let m3 services = m2 services
    let top services = m3 services
  end
end

let run_env_v2 () =
  let metrics = metrics () in
  let env =
    object
      method clock = clock 42
      method metrics = metrics
    end
  in
  let value = Services.run_with_env env (Env_row.V2.top ()) in
  value, metrics.count

let run_args_v2 () =
  let metrics = metrics () in
  let value =
    Services.run_with_env (object end) (Args.V2.top ~clock:(clock 42) ~metrics)
  in
  value, metrics.count

let run_bag_v2 () =
  let metrics = metrics () in
  let services =
    object
      method clock = clock 42
      method metrics = metrics
    end
  in
  let value = Services.run_with_env (object end) (Bag.V2.top services) in
  value, metrics.count

let source_churn_when_leaf_adds_metrics =
  [
    ("env-row", 1, "leaf source changes; inferred top env row grows");
    ("args", 4, "leaf plus every pass-through function grows ~metrics");
    ("bag", 2, "bag type plus leaf change; precision hidden by broad bag");
  ]
