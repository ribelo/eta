module Order = struct type t = int let compare = Int.compare end
module S = Eta_signal_map.Make (Eta_signal.No_observer_error) ()
module K = S.Keyed (Order)
module Unexpected = K.Testing
