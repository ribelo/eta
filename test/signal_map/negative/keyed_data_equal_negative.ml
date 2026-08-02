module Order = struct
  type t = int
  let compare = Int.compare
end
module M = Eta_signal_map.Map.Make (Order)
module S = Eta_signal_map.Make (Eta_signal.No_observer_error) ()
module K = S.Keyed (Order)
let source = S.const (M.set 1 "source" M.empty)
let _ = K.mapi ~data_equal:String.equal source ~f:(fun ~key:_ ~data -> data)
