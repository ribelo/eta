(* Provider slots and the prospective provider graph.

   Every discoverable provider is indexed by one isolation realm and one typed
   coeffect key. Two coeffect keys never alias because they use one realm
   name: the slot pairs the key identity with the realm identity. *)

type slot = {
  key_uid : int;
  realm_uid : int;
}

let slot ~key_uid ~realm_uid = { key_uid; realm_uid }

module Slot = struct
  type t = slot

  let compare a b =
    match Int.compare a.key_uid b.key_uid with
    | 0 -> Int.compare a.realm_uid b.realm_uid
    | nonzero -> nonzero

  let equal a b = compare a b = 0
end

module Slot_map = Map.Make (Slot)

(* Three-color DFS over the prospective provider graph. [edges node] returns
   the entry ids the node depends on through resolved requirement slots.
   Returns the first cycle found as the cycle nodes in dependency order,
   ending where the back edge lands. *)
let find_cycle ~nodes ~edges =
  let color = Hashtbl.create 16 in
  let get node = match Hashtbl.find_opt color node with
    | Some color -> color
    | None -> 0
  in
  let rec dfs trail node =
    Hashtbl.replace color node 1;
    let trail = node :: trail in
    let rec scan = function
      | [] -> None
      | next :: rest -> (
          match get next with
          | 1 ->
              let rec take acc = function
                | [] -> acc
                | x :: xs ->
                    let acc = x :: acc in
                    if Component_entry_id.equal x next then acc else take acc xs
              in
              Some (take [] trail)
          | 2 -> scan rest
          | _ -> (
              match dfs trail next with
              | Some _ as cycle -> cycle
              | None -> scan rest))
    in
    match scan (edges node) with
    | Some _ as cycle -> cycle
    | None ->
        Hashtbl.replace color node 2;
        None
  in
  let rec outer = function
    | [] -> None
    | node :: rest -> (
        if get node = 0 then
          match dfs [] node with
          | Some _ as cycle -> cycle
          | None -> outer rest
        else outer rest)
  in
  outer nodes
