module Left_order = struct
  type t = int

  let compare = Int.compare
end

module Right_order = struct
  type t = int

  let compare = Int.compare
end

module Left = Eta_signal_map.Map.Make (Left_order)
module Right = Eta_signal_map.Map.Make (Right_order)

let convert (map : int Left.t) : int Right.t = map
