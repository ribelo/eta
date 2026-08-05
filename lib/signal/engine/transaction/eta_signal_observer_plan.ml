type counters = {
  mutable enabled : bool;
  mutable candidate_visits : int;
  mutable union_node_visits : int;
  mutable union_edge_visits : int;
  mutable ready_pushes : int;
  mutable ready_pops : int;
  mutable ready_comparisons : int;
  mutable pairwise_search_visits : int;
}

type counter_snapshot = {
  candidate_visits : int;
  union_node_visits : int;
  union_edge_visits : int;
  ready_pushes : int;
  ready_pops : int;
  ready_comparisons : int;
  pairwise_search_visits : int;
}

let create_counters () =
  {
    enabled = false;
    candidate_visits = 0;
    union_node_visits = 0;
    union_edge_visits = 0;
    ready_pushes = 0;
    ready_pops = 0;
    ready_comparisons = 0;
    pairwise_search_visits = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.candidate_visits <- 0;
  counters.union_node_visits <- 0;
  counters.union_edge_visits <- 0;
  counters.ready_pushes <- 0;
  counters.ready_pops <- 0;
  counters.ready_comparisons <- 0;
  counters.pairwise_search_visits <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    candidate_visits = counters.candidate_visits;
    union_node_visits = counters.union_node_visits;
    union_edge_visits = counters.union_edge_visits;
    ready_pushes = counters.ready_pushes;
    ready_pops = counters.ready_pops;
    ready_comparisons = counters.ready_comparisons;
    pairwise_search_visits = counters.pairwise_search_visits;
  }

let succ value = if value = max_int then max_int else value + 1

let note_candidate_visit counters =
  if counters.enabled then
    counters.candidate_visits <- succ counters.candidate_visits

let note_union_node_visit counters =
  if counters.enabled then
    counters.union_node_visits <- succ counters.union_node_visits

let note_union_edge_visit counters =
  if counters.enabled then
    counters.union_edge_visits <- succ counters.union_edge_visits

let note_ready_push counters =
  if counters.enabled then counters.ready_pushes <- succ counters.ready_pushes

let note_ready_pop counters =
  if counters.enabled then counters.ready_pops <- succ counters.ready_pops

let note_ready_comparison counters =
  if counters.enabled then
    counters.ready_comparisons <- succ counters.ready_comparisons

let note_pairwise_search_visit counters =
  if counters.enabled then
    counters.pairwise_search_visits <- succ counters.pairwise_search_visits

type ('observer, 'node) access = {
  node_id : 'node -> int;
  dependencies : 'node -> 'node list;
  observer_id : 'observer -> int;
  observed : 'observer -> 'node;
}

let access ~node_id ~dependencies ~observer_id ~observed =
  { node_id; dependencies; observer_id; observed }

type ('observer, 'node) union_node = {
  union_value : 'node;
  union_id : int;
  mutable union_indegree : int;
  mutable union_dependents : ('observer, 'node) union_node list;
  mutable union_candidates : 'observer list;
  mutable union_min_observer : int option;
  mutable union_emitted : bool;
}

type 'a heap = {
  mutable heap_entries : 'a option array;
  mutable heap_length : int;
  heap_compare : 'a -> 'a -> int;
}

let heap_create compare = { heap_entries = Array.make 4 None; heap_length = 0; heap_compare = compare }

let heap_get heap slot =
  match heap.heap_entries.(slot) with
  | Some value -> value
  | None -> assert false

let heap_swap heap left right =
  let value = heap.heap_entries.(left) in
  heap.heap_entries.(left) <- heap.heap_entries.(right);
  heap.heap_entries.(right) <- value

let heap_grow heap =
  let entries = Array.make (Array.length heap.heap_entries * 2) None in
  Array.blit heap.heap_entries 0 entries 0 heap.heap_length;
  heap.heap_entries <- entries

let heap_push heap value =
  if heap.heap_length = Array.length heap.heap_entries then heap_grow heap;
  let slot = heap.heap_length in
  heap.heap_entries.(slot) <- Some value;
  heap.heap_length <- slot + 1;
  let rec bubble child =
    if child > 0 then
      let parent = (child - 1) / 2 in
      if
        heap.heap_compare (heap_get heap child) (heap_get heap parent) < 0
      then (
        heap_swap heap child parent;
        bubble parent)
  in
  bubble slot

let heap_pop heap =
  if heap.heap_length = 0 then None
  else
    let root = heap_get heap 0 in
    let last = heap.heap_length - 1 in
    heap.heap_entries.(0) <- heap.heap_entries.(last);
    heap.heap_entries.(last) <- None;
    heap.heap_length <- last;
    let rec sink parent =
      let left = (parent * 2) + 1 in
      let right = left + 1 in
      let smallest =
        if
          left < heap.heap_length
          && heap.heap_compare (heap_get heap left) (heap_get heap parent) < 0
        then left
        else parent
      in
      let smallest =
        if
          right < heap.heap_length
          && heap.heap_compare (heap_get heap right) (heap_get heap smallest)
             < 0
        then right
        else smallest
      in
      if smallest <> parent then (
        heap_swap heap parent smallest;
        sink smallest)
    in
    if heap.heap_length > 0 then sink 0;
    Some root

let heap_length heap = heap.heap_length

let plan counters access ~cycle observers =
  let nodes = Hashtbl.create 8 in
  let seen_observers = Hashtbl.create 8 in
  let get_node value =
    let id = access.node_id value in
    match Hashtbl.find_opt nodes id with
    | Some node -> node
    | None ->
        let node =
          {
            union_value = value;
            union_id = id;
            union_indegree = 0;
            union_dependents = [];
            union_candidates = [];
            union_min_observer = None;
            union_emitted = false;
          }
        in
        Hashtbl.add nodes id node;
        node
  in
  let add_candidate observer =
    let observer_id = access.observer_id observer in
    if not (Hashtbl.mem seen_observers observer_id) then (
      Hashtbl.add seen_observers observer_id ();
      note_candidate_visit counters;
      let node = get_node (access.observed observer) in
      node.union_candidates <- observer :: node.union_candidates;
      node.union_min_observer <-
        (match node.union_min_observer with
         | None -> Some observer_id
         | Some current -> Some (min current observer_id)))
  in
  List.iter add_candidate observers;
  let processed = Hashtbl.create 8 in
  let stack =
    Hashtbl.fold (fun _ node stack -> node :: stack) nodes []
  in
  let stack = ref stack in
  while !stack <> [] do
    match !stack with
    | [] -> ()
    | node :: rest ->
        stack := rest;
        if not (Hashtbl.mem processed node.union_id) then (
          Hashtbl.add processed node.union_id node;
          note_union_node_visit counters;
          List.iter
            (fun dependency ->
              note_union_edge_visit counters;
              let dependency_node = get_node dependency in
              node.union_indegree <- node.union_indegree + 1;
              dependency_node.union_dependents <-
                node :: dependency_node.union_dependents;
              stack := dependency_node :: !stack)
            (access.dependencies node.union_value))
  done;
  let compare_groups left right =
    note_ready_comparison counters;
    match (left.union_min_observer, right.union_min_observer) with
    | Some left_observer, Some right_observer ->
        let order = Int.compare left_observer right_observer in
        if order = 0 then Int.compare left.union_id right.union_id else order
    | None, _ | _, None -> assert false
  in
  let ready = heap_create compare_groups in
  let hidden_ready = ref [] in
  let release node =
    List.iter
      (fun dependent ->
        dependent.union_indegree <- dependent.union_indegree - 1;
        if dependent.union_indegree = 0 then
          match dependent.union_candidates with
          | [] -> hidden_ready := dependent :: !hidden_ready
          | _ ->
              note_ready_push counters;
              heap_push ready dependent)
      node.union_dependents
  in
  Hashtbl.iter
    (fun _ node ->
      if node.union_indegree = 0 then
        match node.union_candidates with
        | [] -> hidden_ready := node :: !hidden_ready
        | _ ->
            note_ready_push counters;
            heap_push ready node)
    nodes;
  let emitted = ref 0 in
  let planned = ref [] in
  let emit_hidden node =
    if not node.union_emitted then (
      node.union_emitted <- true;
      incr emitted;
      release node)
  in
  let emit_group node =
    if not node.union_emitted then (
      node.union_emitted <- true;
      incr emitted;
      let observers =
        List.sort
          (fun left right ->
            Int.compare (access.observer_id left) (access.observer_id right))
          node.union_candidates
      in
      planned := List.rev_append observers !planned;
      release node)
  in
  let rec loop () =
    match !hidden_ready with
    | node :: rest ->
        hidden_ready := rest;
        emit_hidden node;
        loop ()
    | [] -> (
        match heap_pop ready with
        | Some node ->
            note_ready_pop counters;
            emit_group node;
            loop ()
        | None -> ())
  in
  loop ();
  if !emitted <> Hashtbl.length nodes then cycle ()
  else List.rev !planned
