module Signal = Eta_signal.Make_no_error ()

let _must_not_typecheck : int Signal.signal =
  Signal.Time.now ~every:(Eta.Duration.ms 1) ()
