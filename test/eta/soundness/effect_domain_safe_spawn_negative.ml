let capture_effect (eff : (int, [ `Boom ]) Eta.Effect.t) =
  let domain = Domain.Safe.spawn (fun () -> ignore eff) in
  Domain.join domain
