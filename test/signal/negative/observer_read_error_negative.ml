module Signal = Eta_signal.Make_no_error ()

let _must_not_typecheck
    (observer : int Signal.Observer.t) : (int, Signal.graph_error) Eta.Effect.t =
  Signal.Observer.read observer
