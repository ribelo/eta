type t = {
  sample :
    trace_id:string ->
    name:string ->
    attrs:(string * string) list ->
    parent:bool ->
    bool;
}

let always_on = { sample = (fun ~trace_id:_ ~name:_ ~attrs:_ ~parent:_ -> true) }

let always_off =
  { sample = (fun ~trace_id:_ ~name:_ ~attrs:_ ~parent:_ -> false) }

let ratio p =
  let p = Float.max 0.0 (Float.min 1.0 p) in
  {
    sample =
      (fun ~trace_id ~name ~attrs:_ ~parent:_ ->
        let bound = 1 lsl 30 in
        let hash = Hashtbl.hash (trace_id, name) land (bound - 1) in
        float_of_int hash /. float_of_int bound < p);
  }

let parent_based ?(root = always_on) () =
  {
    sample =
      (fun ~trace_id ~name ~attrs ~parent ->
        if parent then true else root.sample ~trace_id ~name ~attrs ~parent);
  }
