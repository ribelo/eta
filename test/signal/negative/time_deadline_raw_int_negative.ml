module Signal = Eta_signal.Make_no_error ()

let _must_not_typecheck =
  Signal.Time.deadline ~every:(Eta.Duration.ms 1) 10
