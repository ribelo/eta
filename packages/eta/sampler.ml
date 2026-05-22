type t : immutable_data =
  | Always_on
  | Always_off
  | Ratio of float
  | Parent_based of t

let always_on = Always_on

let always_off = Always_off

let ratio p =
  let p = Float.max 0.0 (Float.min 1.0 p) in
  Ratio p

let parent_based ?(root = always_on) () = Parent_based root

let rec sample t ~trace_id ~name ~attrs ~parent =
  match t with
  | Always_on -> true
  | Always_off -> false
  | Ratio p ->
      let bound = 1 lsl 30 in
      let hash = Hashtbl.hash (trace_id, name) land (bound - 1) in
      float_of_int hash /. float_of_int bound < p
  | Parent_based root ->
      if parent then true else sample root ~trace_id ~name ~attrs ~parent
