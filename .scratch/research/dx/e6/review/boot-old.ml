open Eta

type services = {
  pool : string;
  cache : string;
  metrics : string;
}

let acquire_pool () = Effect.pure "pool"
let release_pool _ = Effect.unit
let acquire_cache () = Effect.pure "cache"
let release_cache _ = Effect.unit
let acquire_metrics () = Effect.pure "metrics"
let release_metrics _ = Effect.unit

let boot body =
  let open Syntax in
  let@ pool =
    Effect.with_resource ~acquire:(acquire_pool ()) ~release:release_pool
  in
  let@ cache =
    Effect.with_resource ~acquire:(acquire_cache ()) ~release:release_cache
  in
  let@ metrics =
    Effect.with_resource ~acquire:(acquire_metrics ()) ~release:release_metrics
  in
  body { pool; cache; metrics }
