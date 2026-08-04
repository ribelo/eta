type counters = {
  mutable enabled : bool;
  mutable static_inserts : int;
  mutable dynamic_inserts : int;
  mutable indexed_removals : int;
  mutable slot_repairs : int;
  mutable invalidated_nodes : int;
  mutable adjacency_search_steps : int;
}

type counter_snapshot = {
  static_inserts : int;
  dynamic_inserts : int;
  indexed_removals : int;
  slot_repairs : int;
  invalidated_nodes : int;
  adjacency_search_steps : int;
}

let create_counters () =
  {
    enabled = false;
    static_inserts = 0;
    dynamic_inserts = 0;
    indexed_removals = 0;
    slot_repairs = 0;
    invalidated_nodes = 0;
    adjacency_search_steps = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.static_inserts <- 0;
  counters.dynamic_inserts <- 0;
  counters.indexed_removals <- 0;
  counters.slot_repairs <- 0;
  counters.invalidated_nodes <- 0;
  counters.adjacency_search_steps <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    static_inserts = counters.static_inserts;
    dynamic_inserts = counters.dynamic_inserts;
    indexed_removals = counters.indexed_removals;
    slot_repairs = counters.slot_repairs;
    invalidated_nodes = counters.invalidated_nodes;
    adjacency_search_steps = counters.adjacency_search_steps;
  }

let succ value = if value = max_int then max_int else value + 1

let note_static_insert counters =
  if counters.enabled then
    counters.static_inserts <- succ counters.static_inserts

let note_dynamic_insert counters =
  if counters.enabled then
    counters.dynamic_inserts <- succ counters.dynamic_inserts

let note_indexed_removal counters =
  if counters.enabled then
    counters.indexed_removals <- succ counters.indexed_removals

let note_slot_repair counters =
  if counters.enabled then counters.slot_repairs <- succ counters.slot_repairs

let note_invalidated_node counters =
  if counters.enabled then
    counters.invalidated_nodes <- succ counters.invalidated_nodes

let note_adjacency_search_step counters =
  if counters.enabled then
    counters.adjacency_search_steps <- succ counters.adjacency_search_steps

type 'a vector = {
  mutable entries : 'a option array;
  mutable length : int;
}

let create_vector () = { entries = Array.make 4 None; length = 0 }
let length vector = vector.length

let grow_to vector capacity =
  let entries = Array.make capacity None in
  Array.blit vector.entries 0 entries 0 vector.length;
  vector.entries <- entries

let grow vector = grow_to vector (Array.length vector.entries * 2)

let reserve_additional vector additional =
  if additional < 0 then
    invalid_arg "Eta_signal_topology.reserve_additional: negative count";
  let required = vector.length + additional in
  let capacity = ref (Array.length vector.entries) in
  while !capacity < required do
    capacity := !capacity * 2
  done;
  if !capacity > Array.length vector.entries then grow_to vector !capacity

let append vector value =
  if vector.length = Array.length vector.entries then grow vector;
  let slot = vector.length in
  vector.entries.(slot) <- Some value;
  vector.length <- slot + 1;
  slot

let get vector slot =
  if slot < 0 || slot >= vector.length then
    invalid_arg "Eta_signal_topology.get: invalid slot";
  match vector.entries.(slot) with
  | Some value -> value
  | None -> assert false

let remove vector slot =
  let removed = get vector slot in
  let last_slot = vector.length - 1 in
  let moved =
    if slot = last_slot then None
    else
      let value = get vector last_slot in
      vector.entries.(slot) <- Some value;
      Some value
  in
  vector.entries.(last_slot) <- None;
  vector.length <- last_slot;
  removed, moved

let iter vector f =
  for slot = 0 to vector.length - 1 do
    f (get vector slot)
  done

let fold vector ~init ~f =
  let acc = ref init in
  iter vector (fun value -> acc := f !acc value);
  !acc

let to_list vector =
  let values = ref [] in
  for slot = vector.length - 1 downto 0 do
    values := get vector slot :: !values
  done;
  !values
