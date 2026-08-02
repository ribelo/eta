module Order = struct
  type t = int

  let compare = Int.compare
end

module Left = Eta_signal_map.Map.Make (Order)
module Right = Eta_signal_map.Map.Make (Order)

let convert (map : int Left.t) : int Right.t = map
