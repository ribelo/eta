module Order = struct type t = int let compare = Int.compare end
module Signal = Eta_signal.Make (Eta_signal.No_observer_error) ()
module Signal_map = Eta_signal_map.Make (Signal.Package)
module S = Signal
module K = Signal_map.Keyed (Order)
module Unexpected = K.Testing
