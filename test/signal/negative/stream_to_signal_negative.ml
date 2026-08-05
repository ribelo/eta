module Signal = Eta_signal.Make_no_error ()
module Signal_stream = Eta_signal_stream.Make (Signal.For_stream)

let _must_not_typecheck = Signal_stream.to_signal
