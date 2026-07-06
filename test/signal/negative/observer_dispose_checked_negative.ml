module Signal = Eta_signal.Make_no_error ()

let _must_not_typecheck observer =
  Signal.Observer.dispose_checked observer
