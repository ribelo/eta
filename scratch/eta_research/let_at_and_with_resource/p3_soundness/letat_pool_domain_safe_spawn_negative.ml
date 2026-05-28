let capture_pool_with_letat (pool : (int, [ `Pool_shutdown ]) Eta.Pool.t) =
  let ( let@ ) f k = f k in
  let effect =
    let@ resource = Eta.Pool.with_resource pool in
    Eta.Effect.pure resource
  in
  let domain = Domain.Safe.spawn (fun () -> ignore effect) in
  Domain.join domain
