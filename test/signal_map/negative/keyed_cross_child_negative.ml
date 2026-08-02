module Order = struct type t = int let compare = Int.compare end
module M = Eta_signal_map.Map.Make (Order)
module A = Eta_signal_map.Make (Eta_signal.No_observer_error) ()
module B = Eta_signal_map.Make (Eta_signal.No_observer_error) ()
module K = A.Keyed (Order)
let source = A.const (M.set 1 "source" M.empty)
let _ = K.mapi source ~f:(fun ~key:_ ~data:_ -> B.const "wrong")
