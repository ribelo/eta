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
  Effect.Scoped.with_3
    ~acquire1:(acquire_pool ())
    ~release1:release_pool
    ~acquire2:(acquire_cache ())
    ~release2:release_cache
    ~acquire3:(acquire_metrics ())
    ~release3:release_metrics
    (fun pool cache metrics ->
      body { pool; cache; metrics })
