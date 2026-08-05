module Order = struct type t = int let compare = Int.compare end
module M = Eta_signal_map.Map.Make (Order)
module Graph_a = Eta_signal.Make (Eta_signal.No_observer_error) ()
module Graph_b = Eta_signal.Make (Eta_signal.No_observer_error) ()
module A = Graph_a
module B = Graph_b
module Signal_map = Eta_signal_map.Make (Graph_a.Package)
module K = Signal_map.Keyed (Order)
let source = B.const (M.set 1 "wrong" M.empty)
let _ = K.mapi source ~f:(fun ~key:_ ~data -> data)
