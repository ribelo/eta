let capture_effect (effect : (int, [ `Boom ]) Eta.Effect.t) =
  let domain = Domain.Safe.spawn (fun () -> ignore effect) in
  Domain.join domain
