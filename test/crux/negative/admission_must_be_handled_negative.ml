let incorrectly_discard_admission (endpoint : int Eta_crux.Endpoint.t) =
  let staged : (unit, Eta_crux.never) Eta.Effect.t =
    Eta_crux.Endpoint.send endpoint 1
  in
  staged
