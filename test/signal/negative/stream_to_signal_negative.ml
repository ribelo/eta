module Signal = Eta_signal.Make_no_error ()

let _must_not_typecheck = Signal.Stream.to_signal
