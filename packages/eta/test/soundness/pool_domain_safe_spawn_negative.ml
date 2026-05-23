let capture_pool (pool : (int, [ `Pool_shutdown ]) Eta.Pool.t) =
  let domain = Domain.Safe.spawn (fun () -> ignore (Eta.Pool.stats pool)) in
  Domain.join domain
