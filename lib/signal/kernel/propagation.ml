(* Selected issue-11 core.  This is a private, synchronous probe kernel. *)

type phase = Idle | Active | Cleanup_pending
type stabilization = Quiescent | Committed
type error = Defect of exn | Reentrant_stabilization

exception Stale_handle
exception Wrong_phase of phase
exception Pass_identity_exhausted
exception Generation_exhausted

type handle = { slot : int; generation : int }

(* Handle records compare by their two integer fields; structural [=] on the
   record would call the generic [caml_equal]. *)
let same_handle left right =
  left.slot = right.slot && left.generation = right.generation

type work = {
  mutable admissions : int;
  mutable claims : int;
  mutable evaluations : int;
  mutable dependency_edges : int;
  mutable propagation_edges : int;
  mutable topology_edits : int;
  mutable dependent_inserts : int;
  mutable adjacency_searches : int;
  mutable cleanup_visits : int;
  mutable rollback_visits : int;
  mutable verdict_steps : int;
}

type keyed_stats = {
  mutable keyed_reconciliation_count : int;
  mutable keyed_input_key_comparison_count : int;
  mutable keyed_input_diff_event_count : int;
  mutable keyed_child_visit_count : int;
  mutable keyed_provisional_addition_count : int;
  mutable keyed_committed_addition_count : int;
  mutable keyed_committed_removal_count : int;
  mutable keyed_reconciliation_rollback_count : int;
  mutable keyed_node_count : int;
  mutable keyed_committed_child_count : int;
}

type scope = {
  mutable valid : bool;
  mutable slot_head : int;
}

type ('a : value_or_null) node = {
  graph : graph;
  handle : handle;
  mutable height : int;
  mutable current : 'a;
  mutable undo : 'a;
  mutable written_in : int;
  mutable flags : int;
  compute : unit -> 'a;
  cutoff : 'a -> 'a -> bool;
  mutable dependencies : packed array;
  mutable dependents : packed list;
  mutable demand : int;
  mutable queued_in : int;
  mutable queue_next : int;
  mutable topology_priority : int;
  mutable keyed_owner : Obj.t option;
  mutable change_listeners : ('a -> unit) list;
  mutable demand_listeners : (bool -> unit) list;
  scope_next : int;
  scope : scope option;
}

and packed = P : ('a : value_or_null). 'a node -> packed [@@unboxed]

and slot = {
  mutable generation : int;
  mutable strong : packed option;
  mutable contents : packed Weak.t option;
  mutable is_free : bool;
}

and topology_action =
  | Created of int
  | Retired of int * packed

and capsule = {
  rollback_capsule : unit -> unit;
  cleanup_capsule : unit -> unit;
}

and graph = {
  mutable phase : phase;
  mutable pass : int;
  mutable slots : slot array;
  mutable slot_count : int;
  mutable free : int array;
  mutable free_length : int;
  mutable quarantine : int array;
  mutable quarantine_length : int;
  mutable journal : int array;
  mutable journal_length : int;
  mutable journal_high_water : int;
  mutable actions : topology_action array;
  mutable action_length : int;
  mutable capsules : capsule array;
  mutable capsule_length : int;
  mutable heads : int array;
  mutable tails : int array;
  mutable highest : int;
  mutable priority_heads : int array;
  mutable priority_tails : int array;
  mutable priority_highest : int;
  mutable admissions : int array;
  mutable admission_length : int;
  mutable current_scope : scope option;
  mutable pending_reclaims : handle array;
  mutable pending_reclaim_length : int;
  mutable suppress_reclaim : bool;
  mutable change_listeners_enabled : bool;
  mutable tombstones : handle array;
  mutable tombstone_length : int;
  mutable keyed_reconciliations_in_pass : int;
  keyed_stats : keyed_stats;
  work : work;
}

type ('a : value_or_null) signal = {
  graph : graph;
  handle : handle;
  node : 'a node;
  packed : packed;
}

type ('a : value_or_null) var = {
  signal : 'a signal;
  accepted : 'a ref;
  source_cutoff : 'a -> 'a -> bool;
}

type demand = packed

(* Packed per-node flags: 1 = constant, 2 = necessary, 4 = in_queue,
   8 = admitted, 16 = reclaim_queued. *)
let node_constant node = node.flags land 1 <> 0
let node_necessary node = node.flags land 2 <> 0
let node_in_queue node = node.flags land 4 <> 0
let node_admitted node = node.flags land 8 <> 0
let node_reclaim_queued node = node.flags land 16 <> 0

let set_node_constant node value =
  node.flags <- if value then node.flags lor 1 else node.flags land (lnot 1)

let set_node_necessary node value =
  node.flags <- if value then node.flags lor 2 else node.flags land (lnot 2)

let set_node_in_queue node value =
  node.flags <- if value then node.flags lor 4 else node.flags land (lnot 4)

let set_node_admitted node value =
  node.flags <- if value then node.flags lor 8 else node.flags land (lnot 8)

let set_node_reclaim_queued node value =
  node.flags <- if value then node.flags lor 16 else node.flags land (lnot 16)


(* Public Signal values carry an uninitialized state, so kernel value slots use
   the nullable [value_or_null] kind. These helpers inspect such a slot without
   knowing its type: [Obj.magic] and [Obj.repr] only accept the non-null [value]
   kind. *)
external magic_or_null :
  ('a : value_or_null) ('b : value_or_null). 'a -> 'b = "%identity"

let[@inline] raw_is_null : ('a : value_or_null). 'a -> bool =
 fun value ->
  match (magic_or_null value : Obj.t or_null) with Null -> true | This _ -> false

let[@inline] raw_same : ('a : value_or_null) ('b : value_or_null). 'a -> 'b -> bool
    =
 fun left right ->
  match
    ( (magic_or_null left : Obj.t or_null),
      (magic_or_null right : Obj.t or_null) )
  with
  | Null, Null -> true
  | This left, This right -> left == right
  | Null, This _ | This _, Null -> false

type ('a : value_or_null) change =
  | Left of 'a
  | Right of 'a
  | Changed of 'a * 'a

type ('key, 'data : value_or_null, 'map : value_or_null) input_ops = {
  empty_input : 'map;
  compare_key : 'key -> 'key -> int;
  iter_diff :
    'map -> 'map -> ('key -> 'data change -> unit) -> unit;
}

type ('key, 'value : value_or_null, 'map : value_or_null) output_ops = {
  empty_output : 'map;
  set_output : 'key -> 'value -> 'map -> 'map;
  remove_output : 'key -> 'map -> 'map;
}

let empty_work () =
  {
    admissions = 0;
    claims = 0;
    evaluations = 0;
    dependency_edges = 0;
    propagation_edges = 0;
    topology_edits = 0;
    dependent_inserts = 0;
    adjacency_searches = 0;
    cleanup_visits = 0;
    rollback_visits = 0;
    verdict_steps = 0;
  }

let keyed_stats_for graph = graph.keyed_stats

let bump_keyed_for graph counter =
  let s = keyed_stats_for graph in
  match counter with
  | `Reconciliation -> if s.keyed_reconciliation_count <> max_int then s.keyed_reconciliation_count <- s.keyed_reconciliation_count + 1
  | `Input_key_comparison -> if s.keyed_input_key_comparison_count <> max_int then s.keyed_input_key_comparison_count <- s.keyed_input_key_comparison_count + 1
  | `Input_diff_event -> if s.keyed_input_diff_event_count <> max_int then s.keyed_input_diff_event_count <- s.keyed_input_diff_event_count + 1
  | `Child_visit -> if s.keyed_child_visit_count <> max_int then s.keyed_child_visit_count <- s.keyed_child_visit_count + 1
  | `Provisional_addition -> if s.keyed_provisional_addition_count <> max_int then s.keyed_provisional_addition_count <- s.keyed_provisional_addition_count + 1
  | `Committed_addition -> if s.keyed_committed_addition_count <> max_int then s.keyed_committed_addition_count <- s.keyed_committed_addition_count + 1
  | `Committed_removal -> if s.keyed_committed_removal_count <> max_int then s.keyed_committed_removal_count <- s.keyed_committed_removal_count + 1
  | `Reconciliation_rollback -> if s.keyed_reconciliation_rollback_count <> max_int then s.keyed_reconciliation_rollback_count <- s.keyed_reconciliation_rollback_count + 1
  | `Node -> if s.keyed_node_count <> max_int then s.keyed_node_count <- s.keyed_node_count + 1
  | `Committed_child -> if s.keyed_committed_child_count <> max_int then s.keyed_committed_child_count <- s.keyed_committed_child_count + 1

let set_keyed_counter_for graph counter value =
  let stats = graph.keyed_stats in
  match counter with
  | `Reconciliation -> stats.keyed_reconciliation_count <- value
  | `Input_key_comparison -> stats.keyed_input_key_comparison_count <- value
  | `Input_diff_event -> stats.keyed_input_diff_event_count <- value
  | `Child_visit -> stats.keyed_child_visit_count <- value
  | `Provisional_addition -> stats.keyed_provisional_addition_count <- value
  | `Committed_addition -> stats.keyed_committed_addition_count <- value
  | `Committed_removal -> stats.keyed_committed_removal_count <- value
  | `Reconciliation_rollback ->
      stats.keyed_reconciliation_rollback_count <- value
  | `Node -> stats.keyed_node_count <- value
  | `Committed_child -> stats.keyed_committed_child_count <- value

let create () =
  {
    phase = Idle;
    pass = 0;
    slots = [||];
    slot_count = 0;
    free = Array.make 8 0;
    free_length = 0;
    quarantine = Array.make 8 0;
    quarantine_length = 0;
    journal = Array.make 16 0;
    journal_length = 0;
    journal_high_water = 0;
    actions = Array.make 8 (Created 0);
    action_length = 0;
    capsules =
      Array.make 8
        { rollback_capsule = (fun () -> ()); cleanup_capsule = (fun () -> ()) };
    capsule_length = 0;
    heads = Array.make 4 (-1);
    tails = Array.make 4 (-1);
    highest = -1;
    priority_heads = Array.make 4 (-1);
    priority_tails = Array.make 4 (-1);
    priority_highest = -1;
    admissions = Array.make 8 0;
    admission_length = 0;
    current_scope = None;
    pending_reclaims = Array.make 16 { slot = -1; generation = -1 };
    pending_reclaim_length = 0;
    suppress_reclaim = false;
    change_listeners_enabled = false;
    tombstones = Array.make 16 { slot = -1; generation = -1 };
    tombstone_length = 0;
    keyed_reconciliations_in_pass = 0;
    keyed_stats =
      {
        keyed_reconciliation_count = 0;
        keyed_input_key_comparison_count = 0;
        keyed_input_diff_event_count = 0;
        keyed_child_visit_count = 0;
        keyed_provisional_addition_count = 0;
        keyed_committed_addition_count = 0;
        keyed_committed_removal_count = 0;
        keyed_reconciliation_rollback_count = 0;
        keyed_node_count = 0;
        keyed_committed_child_count = 0;
      };
    work = empty_work ();
  }

let work graph = graph.work
let enable_change_listeners graph = graph.change_listeners_enabled <- true

let reset_work graph =
  let zero = empty_work () in
  graph.work.admissions <- zero.admissions;
  graph.work.claims <- zero.claims;
  graph.work.evaluations <- zero.evaluations;
  graph.work.dependency_edges <- zero.dependency_edges;
  graph.work.propagation_edges <- zero.propagation_edges;
  graph.work.topology_edits <- zero.topology_edits;
  graph.work.dependent_inserts <- zero.dependent_inserts;
  graph.work.adjacency_searches <- zero.adjacency_searches;
  graph.work.cleanup_visits <- zero.cleanup_visits;
  graph.work.rollback_visits <- zero.rollback_visits;
  graph.work.verdict_steps <- zero.verdict_steps

let grow_int values =
  let next = Array.make (max 1 (2 * Array.length values)) 0 in
  Array.blit values 0 next 0 (Array.length values);
  next

let grow_actions values =
  let next =
    Array.make (max 1 (2 * Array.length values)) (Created 0)
  in
  Array.blit values 0 next 0 (Array.length values);
  next

let grow_capsules values =
  let inert =
    { rollback_capsule = (fun () -> ()); cleanup_capsule = (fun () -> ()) }
  in
  let next = Array.make (max 1 (2 * Array.length values)) inert in
  Array.blit values 0 next 0 (Array.length values);
  next

let ensure_height graph height =
  if height >= Array.length graph.heads then (
    let length = ref (Array.length graph.heads) in
    while height >= !length do
      length := 2 * !length
    done;
    let heads = Array.make !length (-1) in
    let tails = Array.make !length (-1) in
    let priority_heads = Array.make !length (-1) in
    let priority_tails = Array.make !length (-1) in
    Array.blit graph.heads 0 heads 0 (Array.length graph.heads);
    Array.blit graph.tails 0 tails 0 (Array.length graph.tails);
    Array.blit graph.priority_heads 0 priority_heads 0
      (Array.length graph.priority_heads);
    Array.blit graph.priority_tails 0 priority_tails 0
      (Array.length graph.priority_tails);
    graph.heads <- heads;
    graph.tails <- tails;
    graph.priority_heads <- priority_heads;
    graph.priority_tails <- priority_tails)

let slot_contents (slot : slot) =
  match slot.strong, slot.contents with
  | (Some _ as value), _ -> value
  | None, Some contents -> Weak.get contents 0
  | None, None -> None

let set_slot_contents (slot : slot) value =
  slot.strong <- value;
  Option.iter (fun contents -> Weak.set contents 0 value) slot.contents

let weaken_slot (slot : slot) packed =
  let contents =
    match slot.contents with
    | Some contents -> contents
    | None ->
        let contents = Weak.create 1 in
        slot.contents <- Some contents;
        contents
  in
  Weak.set contents 0 (Some packed);
  slot.strong <- None

let make_slot () =
  {
    generation = 0;
    strong = None;
    contents = None;
    is_free = false;
  }

let resolve_slot graph index =
  if index < 0 || index >= graph.slot_count then raise Stale_handle;
  match slot_contents graph.slots.(index) with
  | Some packed -> packed
  | None -> raise Stale_handle

let resolve graph handle =
  if handle.slot < 0 || handle.slot >= graph.slot_count then None
  else
    let slot = graph.slots.(handle.slot) in
    if slot.generation <> handle.generation then None else slot_contents slot

let validate_handle (signal : 'a signal) =
  match resolve signal.graph signal.handle with
  | Some (P node) ->
      same_handle node.handle signal.handle
      && Option.fold ~none:true ~some:(fun scope -> scope.valid) node.scope
  | None -> false


let handle (signal : 'a signal) = signal.handle

let allocate_slot graph =
  if graph.free_length = 0 then (
    let index = graph.slot_count in
    let seed = make_slot () in
    if index = Array.length graph.slots then (
      let next = Array.make (max 1 (2 * index)) seed in
      Array.blit graph.slots 0 next 0 index;
      graph.slots <- next);
    graph.slots.(index) <- make_slot ();
    graph.slot_count <- index + 1;
    { slot = index; generation = 0 })
  else
    let position = graph.free_length - 1 in
    let index = graph.free.(position) in
    let entry = graph.slots.(index) in
    if entry.generation = max_int then raise Generation_exhausted;
    graph.free_length <- position;
    entry.is_free <- false;
    entry.generation <- entry.generation + 1;
    { slot = index; generation = entry.generation }

let push_action graph action =
  if graph.action_length = Array.length graph.actions then
    graph.actions <- grow_actions graph.actions;
  graph.actions.(graph.action_length) <- action;
  graph.action_length <- graph.action_length + 1

let push_capsule graph capsule =
  if graph.capsule_length = Array.length graph.capsules then
    graph.capsules <- grow_capsules graph.capsules;
  graph.capsules.(graph.capsule_length) <- capsule;
  graph.capsule_length <- graph.capsule_length + 1

let add_dependent child parent =
  let P child = child in
  let parent_handle = let P parent = parent in parent.handle in
  child.graph.work.adjacency_searches <-
    child.graph.work.adjacency_searches + 1;
  if
    not
      (List.exists
         (fun (P candidate) -> same_handle candidate.handle parent_handle)
         child.dependents)
  then (
    child.dependents <- parent :: child.dependents;
    child.graph.work.dependent_inserts <-
      child.graph.work.dependent_inserts + 1)

let add_fresh_dependent child parent =
  let P child = child in
  child.dependents <- parent :: child.dependents;
  child.graph.work.dependent_inserts <-
    child.graph.work.dependent_inserts + 1

let iter_unique_dependencies dependencies f =
  match Array.length dependencies with
  | 0 -> ()
  | 1 -> f dependencies.(0)
  | length ->
      for index = 0 to length - 1 do
        let P child = dependencies.(index) in
        let duplicate = ref false in
        let previous = ref 0 in
        while not !duplicate && !previous < index do
          let P candidate = dependencies.(!previous) in
          duplicate := same_handle candidate.handle child.handle;
          incr previous
        done;
        if not !duplicate then f dependencies.(index)
      done

let remove_dependent child parent =
  let P child = child in
  let P parent = parent in
  match child.dependents with
  | P candidate :: rest when same_handle candidate.handle parent.handle ->
      child.dependents <- rest
  | dependents ->
      child.graph.work.adjacency_searches <-
        child.graph.work.adjacency_searches + 1;
      child.dependents <-
        List.filter
          (fun (P candidate) -> not (same_handle candidate.handle parent.handle))
          dependents

let attach parent child =
  let P parent_node = parent in
  if
    not
      (Array.exists
         (fun (P candidate) -> same_handle candidate.handle (let P c = child in c.handle))
         parent_node.dependencies)
  then (
    parent_node.dependencies <-
      Array.append parent_node.dependencies [| child |];
    add_dependent child parent;
    parent_node.graph.work.topology_edits <-
      parent_node.graph.work.topology_edits + 1)

let detach parent child =
  let P parent_node = parent in
  let P child_node = child in
  parent_node.dependencies <-
    Array.of_list
      (Array.fold_right
         (fun (P candidate as packed) rest ->
           if same_handle candidate.handle child_node.handle then rest else packed :: rest)
         parent_node.dependencies []);
  remove_dependent child parent;
  parent_node.graph.work.topology_edits <-
    parent_node.graph.work.topology_edits + 1

(* Replace [old] with [child] in [parent]'s dependency array in place instead
   of detach-then-attach, which rebuilds the array twice. Falls back to
   [attach] when [old] is not present. Charges the same two topology edits. *)
let replace_dependency parent old child =
  let P parent_node = parent in
  let P old_node = old in
  let length = Array.length parent_node.dependencies in
  let found = ref (-1) in
  for index = 0 to length - 1 do
    match parent_node.dependencies.(index) with
    | P candidate when same_handle candidate.handle old_node.handle -> found := index
    | P _ -> ()
  done;
  match !found with
  | -1 -> attach parent child
  | index ->
      parent_node.dependencies.(index) <- child;
      remove_dependent old parent;
      add_dependent child parent;
      parent_node.graph.work.topology_edits <-
        parent_node.graph.work.topology_edits + 2

let make_node ?(constant = false) graph ~height ~dependencies ~compute ~cutoff
    ~initial =
  if graph.phase = Cleanup_pending then raise (Wrong_phase graph.phase);
  let handle = allocate_slot graph in
  let scope_next =
    Option.fold ~none:(-1) ~some:(fun scope -> scope.slot_head)
      graph.current_scope
  in
  let node =
    {
      graph;
      handle;
      height;
      current = initial;
      undo = initial;
      written_in = -1;
      flags = if constant then 1 else 0;
      compute;
      cutoff;
      dependencies;
      dependents = [];
      demand = 0;
      queued_in = -1;
      queue_next = -1;
      topology_priority = 0;
      keyed_owner = None;
      change_listeners = [];
      demand_listeners = [];
      scope_next;
      scope = graph.current_scope;
    }
  in
  let packed = P node in
  set_slot_contents graph.slots.(handle.slot) (Some packed);
  Option.iter
    (fun (scope : scope) -> scope.slot_head <- handle.slot)
    graph.current_scope;
  (match Array.length dependencies with
  | 0 -> ()
  | 1 -> add_fresh_dependent dependencies.(0) packed
  | _ ->
      iter_unique_dependencies dependencies
        (fun child -> add_fresh_dependent child packed));
  ensure_height graph height;
  if graph.phase = Active then push_action graph (Created handle.slot);
  { graph; handle; node; packed }

let var ?(cutoff = ( == )) graph initial =
  let accepted = ref initial in
  let signal =
    make_node graph ~height:0 ~dependencies:[||]
      ~compute:(fun () -> !accepted) ~cutoff ~initial
  in
  { signal; accepted; source_cutoff = cutoff }

let watch variable = variable.signal

let constant_compute () = failwith "selected_core: evaluated constant"

let const graph value =
  make_node ~constant:true graph ~height:0 ~dependencies:[||]
    ~compute:constant_compute
    ~cutoff:(fun _ _ -> true) ~initial:value

let map ?(cutoff = ( == )) f child =
  if not (validate_handle child) then raise Stale_handle;
  let initial = f child.node.current in
  make_node child.graph ~height:(child.node.height + 1)
    ~dependencies:[| child.packed |]
    ~compute:(fun () -> f child.node.current) ~cutoff ~initial

let map2 ?(cutoff = ( == )) f (left : 'a signal) (right : 'b signal) =
  if left.graph != right.graph then invalid_arg "selected_core: graph mismatch";
  if not (validate_handle left && validate_handle right) then raise Stale_handle;
  let initial = f left.node.current right.node.current in
  make_node left.graph
    ~height:(1 + max left.node.height right.node.height)
    ~dependencies:[| left.packed; right.packed |]
    ~compute:(fun () -> f left.node.current right.node.current)
    ~cutoff ~initial

let enqueue (P node) =
  let graph = node.graph in
  if node_necessary node && node.queued_in <> graph.pass then (
    node.queued_in <- graph.pass;
    node.queue_next <- -1;
    set_node_in_queue node true;
    ensure_height graph node.height;
    let heads, tails =
      if node.topology_priority > 0 then
        graph.priority_heads, graph.priority_tails
      else graph.heads, graph.tails
    in
    if tails.(node.height) = -1 then (
      heads.(node.height) <- node.handle.slot;
      tails.(node.height) <- node.handle.slot)
    else (
      let P tail = resolve_slot graph tails.(node.height) in
      tail.queue_next <- node.handle.slot;
      tails.(node.height) <- node.handle.slot);
    if node.topology_priority > 0 then (
      if node.height > graph.priority_highest then
        graph.priority_highest <- node.height)
    else if node.height > graph.highest then graph.highest <- node.height)

(* Shared initializer body: enqueue [packed] when it is still live, necessary,
   and uninitialized. The graph stores packed nodes in its initializer list
   instead of allocating one closure per created node. *)
let enqueue_if_uninitialized graph (P node as packed) =
  match resolve graph node.handle with
  | Some (P current) ->
      if
        same_handle current.handle node.handle
        && (match node.scope with None -> true | Some scope -> scope.valid)
        && node_necessary node
        && raw_is_null node.current
      then enqueue packed
  | None -> ()

let enqueue_deferred (P node as packed) =
  let topology_priority = node.topology_priority in
  node.topology_priority <- 0;
  Fun.protect
    ~finally:(fun () -> node.topology_priority <- topology_priority)
    (fun () -> enqueue packed)

let unlink_queued_node (P target) =
  let graph = target.graph in
  if target.queued_in = graph.pass then (
    let removed = ref false in
    let remove_from heads tails =
      for height = 0 to Array.length heads - 1 do
        if not !removed then (
          let previous = ref None in
          let slot = ref heads.(height) in
          while !slot <> -1 && not !removed do
            match slot_contents graph.slots.(!slot) with
            | None -> slot := -1
            | Some (P node as packed) ->
                let next = node.queue_next in
                if same_handle node.handle target.handle then (
                  (match !previous with
                  | None -> heads.(height) <- next
                  | Some (P previous) -> previous.queue_next <- next);
                  if tails.(height) = node.handle.slot then
                    tails.(height) <-
                      (match !previous with
                      | None -> -1
                      | Some (P previous) -> previous.handle.slot);
                  node.queue_next <- -1;
                  node.queued_in <- -1;
                  set_node_in_queue node false;
                  removed := true)
                else (
                  previous := Some packed;
                  slot := next)
          done)
      done
    in
    remove_from graph.priority_heads graph.priority_tails;
    remove_from graph.heads graph.tails)

let retain_admission graph node =
  if not (node_admitted node) then (
    if graph.admission_length = Array.length graph.admissions then
      graph.admissions <- grow_int graph.admissions;
    set_node_admitted node true;
    graph.admissions.(graph.admission_length) <- node.handle.slot;
    graph.admission_length <- graph.admission_length + 1)

let rec activate (P node as packed) =
  node.demand <- node.demand + 1;
  if not (node_necessary node) then (
    let slot = node.graph.slots.(node.handle.slot) in
    if slot.strong = None then set_slot_contents slot (Some packed);
    let reverse_edges_detached = node_reclaim_queued node in
    set_node_reclaim_queued node false;
    set_node_necessary node true;
    (match Array.length node.dependencies with
    | 0 -> ()
    | 1 ->
        let dependency = node.dependencies.(0) in
        if reverse_edges_detached then
          add_fresh_dependent dependency packed;
        activate dependency
    | _ ->
        iter_unique_dependencies node.dependencies
          (fun dependency ->
            if reverse_edges_detached then
              add_fresh_dependent dependency packed;
            activate dependency));
    List.iter (fun notify -> notify true) node.demand_listeners;
    if Array.length node.dependencies = 0 && not (node_constant node) then (
      retain_admission node.graph node;
      enqueue packed))

let demand signal =
  if not (validate_handle signal) then raise Stale_handle;
  activate signal.packed;
  signal.packed

let rec deactivate (P node as packed) =
  if node.demand > 0 then node.demand <- node.demand - 1;
  if node_necessary node && node.demand = 0 then (
    set_node_necessary node false;
    if not (node_reclaim_queued node) then (
      set_node_reclaim_queued node true;
      if not node.graph.suppress_reclaim then (
        let graph = node.graph in
        if
          graph.pending_reclaim_length = Array.length graph.pending_reclaims
        then (
          let next =
            Array.make (2 * Array.length graph.pending_reclaims)
              { slot = -1; generation = -1 }
          in
          Array.blit graph.pending_reclaims 0 next 0
            graph.pending_reclaim_length;
          graph.pending_reclaims <- next);
        graph.pending_reclaims.(graph.pending_reclaim_length) <- node.handle;
        graph.pending_reclaim_length <- graph.pending_reclaim_length + 1));
    List.iter (fun notify -> notify false) node.demand_listeners;
    (match Array.length node.dependencies with
    | 0 -> ()
    | 1 ->
        let dependency = node.dependencies.(0) in
        remove_dependent dependency packed;
        deactivate dependency
    | _ ->
        iter_unique_dependencies node.dependencies
          (fun dependency ->
            remove_dependent dependency packed;
            deactivate dependency));
    if not node.graph.suppress_reclaim then
      weaken_slot node.graph.slots.(node.handle.slot) packed)

let release demand = deactivate demand

let value signal =
  if not (validate_handle signal) then raise Stale_handle;
  signal.node.current

let[@inline always] record_first_write (node : 'a node) =
  let graph = node.graph in
  if node.written_in <> graph.pass then (
    if graph.journal_length = Array.length graph.journal then
      graph.journal <- grow_int graph.journal;
    node.undo <- node.current;
    node.written_in <- graph.pass;
    graph.journal.(graph.journal_length) <- node.handle.slot;
    graph.journal_length <- graph.journal_length + 1;
    if graph.journal_length > graph.journal_high_water then
      graph.journal_high_water <- graph.journal_length)

let set graph variable candidate =
  if variable.signal.graph != graph then
    invalid_arg "selected_core: graph mismatch";
  graph.work.admissions <- graph.work.admissions + 1;
  if not (variable.source_cutoff !(variable.accepted) candidate) then (
    variable.accepted := candidate;
    retain_admission graph variable.signal.node;
    enqueue variable.signal.packed)

type pending_work = {
  mutable pending_claims : int;
  mutable pending_evaluations : int;
  mutable pending_dependency_edges : int;
  mutable pending_propagation_edges : int;
}

let[@inline always] flush_pending_work (pending @ local) work =
  work.claims <- work.claims + pending.pending_claims;
  work.evaluations <- work.evaluations + pending.pending_evaluations;
  work.dependency_edges <-
    work.dependency_edges + pending.pending_dependency_edges;
  work.propagation_edges <-
    work.propagation_edges + pending.pending_propagation_edges

let rec enqueue_parents (pending @ local) = function
  | [] -> ()
  | (P parent_node as parent) :: parents ->
      pending.pending_propagation_edges <-
        pending.pending_propagation_edges + 1;
      if node_necessary parent_node then enqueue parent;
      enqueue_parents pending parents

let rec evaluate_from (pending @ local) changed_before (P node) =
  let graph = node.graph in
  pending.pending_claims <- pending.pending_claims + 1;
  let changed =
    if node_constant node then false
    else (
      let dependency_count = Array.length node.dependencies in
      if dependency_count > 0 then (
        pending.pending_evaluations <- pending.pending_evaluations + 1;
        pending.pending_dependency_edges <-
          pending.pending_dependency_edges + dependency_count);
      let next = node.compute () in
      if node.cutoff node.current next then false
      else (
        record_first_write node;
        node.current <- next;
        if graph.change_listeners_enabled then
          List.iter (fun notify -> notify next) node.change_listeners;
        true))
  in
  if changed then
    match node.dependents with
    | [ (P parent_node as parent) ]
      when node_necessary parent_node
           && Array.length parent_node.dependencies = 1
           && parent_node.height = node.height + 1 ->
        pending.pending_propagation_edges <-
          pending.pending_propagation_edges + 1;
        evaluate_from pending true parent
    | parents ->
        enqueue_parents pending parents;
        true
  else changed_before

let evaluate (P node as packed) =
  let local_ pending =
    {
      pending_claims = 0;
      pending_evaluations = 0;
      pending_dependency_edges = 0;
      pending_propagation_edges = 0;
    }
  in
  match evaluate_from pending false packed with
  | changed ->
      flush_pending_work pending node.graph.work;
      changed
  | exception exn ->
      flush_pending_work pending node.graph.work;
      raise exn

let evaluate_node = evaluate

let pop graph heads tails height =
  let slot = heads.(height) in
  if slot = -1 then None
  else
    let resolved = slot_contents graph.slots.(slot) in
    match resolved with
    | None -> raise Stale_handle
    | Some (P node) ->
        heads.(height) <- node.queue_next;
        if node.queue_next = -1 then tails.(height) <- -1;
        node.queue_next <- -1;
        set_node_in_queue node false;
        resolved

let rec pop_from graph heads tails highest height =
  if height > highest then None
  else
    match pop graph heads tails height with
    | None -> pop_from graph heads tails highest (height + 1)
    | Some node -> Some node

let rec drain_from graph changed =
  match
    pop_from graph graph.priority_heads graph.priority_tails
      graph.priority_highest 0
  with
  | Some node -> drain_from graph (evaluate node || changed)
  | None -> (
      match pop_from graph graph.heads graph.tails graph.highest 0 with
      | Some node -> drain_from graph (evaluate node || changed)
      | None -> changed)

let drain graph = drain_from graph false

let begin_pass graph =
  if graph.phase <> Idle then raise (Wrong_phase graph.phase);
  if graph.pass = max_int then raise Pass_identity_exhausted;
  graph.phase <- Active;
  graph.keyed_reconciliations_in_pass <- 0;
  graph.action_length <- 0;
  graph.capsule_length <- 0;
  graph.quarantine_length <- 0

let retire_packed graph (P node as packed) =
  if graph.phase <> Active then raise (Wrong_phase graph.phase);
  unlink_queued_node packed;
  if node_necessary node then (
    set_node_necessary node false;
    node.demand <- 0;
    set_node_reclaim_queued node true;
    List.iter (fun notify -> notify false) node.demand_listeners;
    iter_unique_dependencies node.dependencies
      (fun dependency ->
        remove_dependent dependency packed;
        deactivate dependency));
  let entry = graph.slots.(node.handle.slot) in
  set_slot_contents entry None;
  Option.iter (fun scope -> scope.valid <- false) node.scope;
  if graph.quarantine_length = Array.length graph.quarantine then
    graph.quarantine <- grow_int graph.quarantine;
  graph.quarantine.(graph.quarantine_length) <- node.handle.slot;
  graph.quarantine_length <- graph.quarantine_length + 1;
  push_action graph (Retired (node.handle.slot, packed))

let retire_scope graph scope =
  let rec loop slot =
    if slot <> -1 then
      let (P node as packed) = resolve_slot graph slot in
      let next = node.scope_next in
      retire_packed graph packed;
      loop next
  in
  loop scope.slot_head

let retire signal =
  if not (validate_handle signal) then raise Stale_handle;
  retire_packed signal.graph (P signal.node)

let restore_retired graph =
  for index = graph.action_length - 1 downto 0 do
    match graph.actions.(index) with
    | Retired (slot, (P node as packed)) ->
        set_slot_contents graph.slots.(slot) (Some packed);
        Option.iter (fun scope -> scope.valid <- true) node.scope;
        graph.work.rollback_visits <- graph.work.rollback_visits + 1
    | Created _ -> ()
  done

let rollback_values graph =
  for index = graph.journal_length - 1 downto 0 do
    let P node = resolve_slot graph graph.journal.(index) in
    node.current <- node.undo;
    node.written_in <- -1;
    graph.work.rollback_visits <- graph.work.rollback_visits + 1
  done;
  graph.journal_length <- 0

let push_free graph slot =
  let entry = graph.slots.(slot) in
  if not entry.is_free then (
    if graph.free_length = Array.length graph.free then
      graph.free <- grow_int graph.free;
    entry.is_free <- true;
    graph.free.(graph.free_length) <- slot;
    graph.free_length <- graph.free_length + 1)

let discard_created graph =
  for index = graph.action_length - 1 downto 0 do
    match graph.actions.(index) with
    | Created slot ->
        let entry = graph.slots.(slot) in
        (match slot_contents entry with
        | Some (P node) ->
            Option.iter (fun scope -> scope.valid <- false) node.scope
        | None -> ());
        set_slot_contents entry None;
        push_free graph slot;
        graph.work.rollback_visits <- graph.work.rollback_visits + 1
    | Retired _ -> ()
  done

let clear_queues graph =
  Array.fill graph.heads 0 (Array.length graph.heads) (-1);
  Array.fill graph.tails 0 (Array.length graph.tails) (-1);
  graph.highest <- -1;
  Array.fill graph.priority_heads 0
    (Array.length graph.priority_heads) (-1);
  Array.fill graph.priority_tails 0
    (Array.length graph.priority_tails) (-1);
  graph.priority_highest <- -1;
  for slot = 0 to graph.slot_count - 1 do
    match slot_contents graph.slots.(slot) with
    | Some (P node) ->
        node.queue_next <- -1;
        set_node_in_queue node false
    | None -> ()
  done

let replay_admissions graph =
  for index = 0 to graph.admission_length - 1 do
    match slot_contents graph.slots.(graph.admissions.(index)) with
    | Some packed ->
        let P node = packed in
        node.queued_in <- -1;
        enqueue packed
    | None -> ()
  done

let rollback graph =
  (* Retired identities and topology first, then values, then tentative nodes. *)
  restore_retired graph;
  for index = graph.capsule_length - 1 downto 0 do
    graph.capsules.(index).rollback_capsule ()
  done;
  rollback_values graph;
  discard_created graph;
  clear_queues graph;
  graph.action_length <- 0;
  graph.capsule_length <- 0;
  graph.quarantine_length <- 0;
  graph.pass <- graph.pass + 1;
  graph.phase <- Idle;
  replay_admissions graph

let commit graph =
  (* Successful publication is only fixed scalar work. *)
  graph.journal_length <- 0;
  graph.pass <- graph.pass + 1;
  graph.phase <-
    (if graph.action_length = 0 && graph.capsule_length = 0 then Idle
     else Cleanup_pending);
  graph.work.verdict_steps <- graph.work.verdict_steps + 3

let cleanup graph =
  if graph.phase <> Cleanup_pending then raise (Wrong_phase graph.phase);
  for index = 0 to graph.capsule_length - 1 do
    graph.capsules.(index).cleanup_capsule ();
    graph.work.cleanup_visits <- graph.work.cleanup_visits + 1
  done;
  for index = 0 to graph.action_length - 1 do
    (match graph.actions.(index) with
    | Retired (slot, _) -> push_free graph slot
    | Created _ -> ());
    graph.actions.(index) <- Created 0;
    graph.work.cleanup_visits <- graph.work.cleanup_visits + 1
  done;
  graph.action_length <- 0;
  graph.capsule_length <- 0;
  graph.quarantine_length <- 0;
  graph.phase <- Idle

let remember_tombstone graph handle =
  if graph.tombstone_length < Array.length graph.tombstones then (
    graph.tombstones.(graph.tombstone_length) <- handle;
    graph.tombstone_length <- graph.tombstone_length + 1)
  else (
    Array.blit graph.tombstones 1 graph.tombstones 0
      (Array.length graph.tombstones - 1);
    graph.tombstones.(Array.length graph.tombstones - 1) <- handle)

let reclaim_unreachable graph =
  if graph.phase <> Idle then raise (Wrong_phase graph.phase);
  let retained = ref 0 in
  for index = 0 to graph.pending_reclaim_length - 1 do
    let handle = graph.pending_reclaims.(index) in
    let keep =
      if handle.slot >= 0 && handle.slot < graph.slot_count then
        let entry = graph.slots.(handle.slot) in
        if entry.generation <> handle.generation || entry.is_free then false
        else
          match slot_contents entry with
          | None ->
              remember_tombstone graph handle;
              push_free graph handle.slot;
              false
          | Some (P node) when node_necessary node ->
              set_node_reclaim_queued node false;
              false
          | Some _ -> true
      else false
    in
    if keep then (
      graph.pending_reclaims.(!retained) <- handle;
      incr retained)
  done;
  graph.pending_reclaim_length <- !retained

let release_unreachable_roots = reclaim_unreachable
let handle_is_live graph handle = Option.is_some (resolve graph handle)
let tombstone_count graph = graph.tombstone_length

let count_necessary graph =
  let count = ref 0 in
  for slot = 0 to graph.slot_count - 1 do
    match slot_contents graph.slots.(slot) with
    | Some (P node) when node_necessary node -> incr count
    | Some _ | None -> ()
  done;
  !count

let unlink_unnecessary_queued graph =
  for slot = 0 to graph.slot_count - 1 do
    match slot_contents graph.slots.(slot) with
    | Some (P node as packed) when not (node_necessary node) ->
        unlink_queued_node packed
    | Some _ | None -> ()
  done

let rec retire_scope_loop graph scope count slot =
  if slot = -1 then count
  else
    match slot_contents graph.slots.(slot) with
    | Some (P node as packed) ->
        let next = node.scope_next in
        (match node.scope with
        | Some owner when owner == scope ->
            unlink_queued_node packed;
            retire_packed graph packed;
            retire_scope_loop graph scope (count + 1) next
        | None | Some _ -> count)
    | None -> count

let retire_scope_chain graph scope =
  retire_scope_loop graph scope 0 scope.slot_head

let enqueue_all_uninitialized_necessary graph =
  for slot = 0 to graph.slot_count - 1 do
    match slot_contents graph.slots.(slot) with
    | Some (P node as packed)
      when node_necessary node
           && Array.length node.dependencies > 0
           && raw_is_null node.current ->
        enqueue packed
    | Some _ | None -> ()
  done

let clear_queue_mark (P node) = node.queued_in <- -1

let cancel_admission graph (P node as packed) =
  let retained = ref 0 in
  for index = 0 to graph.admission_length - 1 do
    let slot = graph.admissions.(index) in
    if slot <> node.handle.slot then (
      graph.admissions.(!retained) <- slot;
      incr retained)
  done;
  graph.admission_length <- !retained;
  set_node_admitted node false;
  unlink_queued_node packed

let public_node_counts graph =
  let total = ref 0 and necessary = ref 0 and dirty = ref 0 in
  for slot = 0 to graph.slot_count - 1 do
    match slot_contents graph.slots.(slot) with
    | None -> ()
    | Some (P node) ->
        let internal_source =
          not (node_constant node) && Array.length node.dependencies = 0
        in
        if not internal_source then incr total;
        if node_necessary node && not internal_source then incr necessary;
        if node_admitted node then incr dirty
  done;
  (!total, !necessary, !dirty)

let create_scope () = { valid = true; slot_head = -1 }
let scope_valid scope = scope.valid
let current_scope graph = graph.current_scope
let current_pass graph = graph.pass

let invalidate_scope_chain graph scope =
  let retired = retire_scope_chain graph scope in
  scope.valid <- false;
  retired

let prepend_change_listener (P node)
    (listener : ('a : value_or_null). 'a -> unit) =
  node.change_listeners <- listener :: node.change_listeners

let move_dependent_last (P dependency) handle =
  let own, others =
    List.partition
      (fun (P candidate) -> same_handle candidate.handle handle)
      dependency.dependents
  in
  dependency.dependents <- others @ own

let rec ensure_parent_height graph ?(current = false) (P node as packed)
    minimum =
  if node.height < minimum then (
    if not current then unlink_queued_node packed;
    node.height <- minimum;
    ensure_height graph minimum;
    if not current then (
      node.queued_in <- -1;
      if node_necessary node then enqueue packed);
    List.iter
      (fun parent -> ensure_parent_height graph parent (minimum + 1))
      node.dependents)

let dependency_subgraph root =
  let seen = Hashtbl.create 8 in
  let nodes = ref [] in
  let rec visit (P node as packed) =
    if not (Hashtbl.mem seen node.handle.slot) then (
      Hashtbl.add seen node.handle.slot ();
      nodes := packed :: !nodes;
      Array.iter visit node.dependencies)
  in
  visit root;
  !nodes

let adjust_topology_priority delta nodes =
  List.iter
    (fun (P node as packed) ->
      node.topology_priority <- node.topology_priority + delta;
      if node_in_queue node then (
        unlink_queued_node packed;
        enqueue packed))
    nodes

let enqueue_uninitialized_topology (P root as packed) =
  if Array.length root.dependencies = 0 then (
    if raw_is_null root.current then enqueue packed)
  else
    let seen = Hashtbl.create 8 in
    let rec visit (P node as packed) =
      if not (Hashtbl.mem seen node.handle.slot) then (
        Hashtbl.add seen node.handle.slot ();
        Array.iter visit node.dependencies;
        if raw_is_null node.current then enqueue packed)
    in
    visit packed

let distinct_scopes root =
  let seen = Hashtbl.create 8 in
  let scopes = ref [] in
  let rec visit (P node) =
    if not (Hashtbl.mem seen node.handle.slot) then (
      Hashtbl.add seen node.handle.slot ();
      match node.scope with
      | None -> ()
      | Some scope ->
          if not (List.exists (fun candidate -> candidate == scope) !scopes)
          then scopes := scope :: !scopes;
          Array.iter visit node.dependencies)
  in
  visit root;
  !scopes

let reaches_handle root target =
  let seen = Hashtbl.create 8 in
  let rec visit (P node) =
    if same_handle node.handle target then true
    else if Hashtbl.mem seen node.handle.slot then false
    else (
      Hashtbl.add seen node.handle.slot ();
      Array.exists visit node.dependencies)
  in
  visit root

let rec enqueue_reactivated (P node as packed) =
  Array.iter
    (fun (P dependency as packed) ->
      if Array.length dependency.dependencies > 0 then
        enqueue_reactivated packed)
    node.dependencies;
  if Array.length node.dependencies > 0 then enqueue packed

let unlink_queued_descendants graph roots =
  match roots with
  | [] -> ()
  | _ :: _ ->
      let seen = Hashtbl.create 16 in
      let rec walk (P node as packed) =
        if not (Hashtbl.mem seen node.handle.slot) then (
          Hashtbl.add seen node.handle.slot ();
          unlink_queued_node packed;
          List.iter walk node.dependents)
      in
      List.iter walk roots

let enqueue_stale_freshness graph ~bind_order ~custom_cutoff_nodes
    ~duplicate_dependency_nodes =
  match bind_order with
  | [] when Hashtbl.length duplicate_dependency_nodes = 0 -> false
  | _ ->
  let stale = ref false in
  let rec check = function
    | [] -> ()
    | handle :: rest -> (
        match slot_contents graph.slots.(handle.slot) with
        | Some (P node as packed)
          when same_handle node.handle handle
               && node_necessary node
               && Array.length node.dependencies > 1 ->
            let P inner =
              node.dependencies.(Array.length node.dependencies - 1)
            in
            if not (raw_same node.current inner.current) then (
              enqueue packed;
              stale := true)
        | Some _ | None -> ());
        check rest
  in
  check bind_order;
  if Hashtbl.length duplicate_dependency_nodes <> 0 then (
    let committed_pass = graph.pass - 1 in
    let seen_descendants = Hashtbl.create 16 in
    let rec enqueue_descendants (P node as packed) =
      if not (Hashtbl.mem seen_descendants node.handle.slot) then (
        Hashtbl.add seen_descendants node.handle.slot ();
        if node_necessary node then enqueue packed;
        List.iter enqueue_descendants node.dependents)
    in
    Hashtbl.iter
      (fun slot handle ->
        match slot_contents graph.slots.(slot) with
        | Some (P node)
          when same_handle node.handle handle && node_necessary node ->
          let dependency_changed =
            Array.exists
              (fun (P dependency) -> dependency.written_in = committed_pass)
              node.dependencies
          in
          let custom_dependency =
            Array.exists
              (fun (P dependency) ->
                Hashtbl.find_opt custom_cutoff_nodes dependency.handle.slot
                = Some dependency.handle)
              node.dependencies
          in
          if dependency_changed && not custom_dependency then (
            enqueue (P node);
            List.iter enqueue_descendants node.dependents;
            stale := true)
        | Some _ | None -> ())
      duplicate_dependency_nodes);
  !stale

let reinstall_freed graph handle packed =
  (* The handle still matches the slot generation, but the slot sits on the
     free list: remove it from the list and reinstall the node as occupied.
     Returns [false] when the generation has moved on. *)
  let entry = graph.slots.(handle.slot) in
  if entry.generation <> handle.generation then false
  else (
    let retained = ref 0 in
    for index = 0 to graph.free_length - 1 do
      if graph.free.(index) <> handle.slot then (
        graph.free.(!retained) <- graph.free.(index);
        incr retained)
    done;
    graph.free_length <- !retained;
    entry.is_free <- false;
    set_slot_contents entry (Some packed);
    true)

let clear_admissions graph =
  for index = 0 to graph.admission_length - 1 do
    match slot_contents graph.slots.(graph.admissions.(index)) with
    | Some (P node) ->
        set_node_admitted node false
    | None -> ()
  done;
  graph.admission_length <- 0

let run_stabilization graph checkpoint =
  if graph.phase <> Idle then raise Exit
  else
    match
      begin_pass graph;
      let changed = drain graph in
      Option.iter (fun checkpoint -> checkpoint ()) checkpoint;
      if Option.is_some checkpoint then clear_queues graph;
      commit graph;
      clear_admissions graph;
      if graph.phase = Cleanup_pending then cleanup graph;
      changed
    with
    | changed -> changed
    | exception exn ->
        for _ = 1 to graph.keyed_reconciliations_in_pass do
          bump_keyed_for graph `Reconciliation_rollback;
        done;
        rollback graph;
        raise exn

let stabilize ?checkpoint graph =
  match run_stabilization graph checkpoint with
  | changed -> Ok (if changed then Committed else Quiescent)
  | exception Exit -> Error Reentrant_stabilization
  | exception exn -> Error (Defect exn)

let stabilize_unit graph = ignore (run_stabilization graph None)

let with_scope graph scope f =
  let previous = graph.current_scope in
  graph.current_scope <- Some scope;
  Fun.protect ~finally:(fun () -> graph.current_scope <- previous) f

type ('a, 'b) bind_owner = {
  bind_signal : 'b signal;
  source : 'a signal;
  selector : 'a -> 'b signal;
  mutable selected_source : 'a;
  mutable inner : 'b signal;
  mutable inner_scope : scope;
  mutable rollback_inner : 'b signal;
  mutable rollback_scope : scope;
  mutable tentative_inner : 'b signal;
}

let bind_owner ?(cutoff = ( == )) (source : 'a signal) ~f =
  let graph = source.graph in
  enable_change_listeners graph;
  let scope = { valid = true; slot_head = -1 } in
  let inner : 'b signal =
    with_scope graph scope (fun () -> f source.node.current)
  in
  if inner.graph != graph then invalid_arg "selected_core: graph mismatch";
  let owner_ref = ref None in
  let switch_dependency owner old_inner fresh_inner =
    owner.bind_signal.node.dependencies.(1) <- fresh_inner.packed;
    remove_dependent old_inner.packed owner.bind_signal.packed;
    add_dependent fresh_inner.packed owner.bind_signal.packed;
    if node_necessary owner.bind_signal.node then (
      graph.suppress_reclaim <- true;
      deactivate old_inner.packed;
      graph.suppress_reclaim <- false;
      activate fresh_inner.packed);
    graph.work.topology_edits <- graph.work.topology_edits + 2
  in
  let capsule =
    {
      rollback_capsule =
        (fun () ->
          let owner = Option.get !owner_ref in
          let old_inner = owner.rollback_inner in
          let old_scope = owner.rollback_scope in
          let fresh_inner = owner.tentative_inner in
          switch_dependency owner fresh_inner old_inner;
          owner.selected_source <- source.node.undo;
          owner.inner <- old_inner;
          owner.inner_scope <- old_scope;
          owner.rollback_inner <- old_inner;
          owner.rollback_scope <- old_scope;
          owner.tentative_inner <- old_inner);
      cleanup_capsule =
        (fun () ->
          let owner = Option.get !owner_ref in
          owner.rollback_scope.valid <- false;
          owner.rollback_inner <- owner.inner;
          owner.rollback_scope <- owner.inner_scope;
          owner.tentative_inner <- owner.inner);
    }
  in
  let compute () =
    let owner = Option.get !owner_ref in
    let next_source = source.node.current in
    if owner.selected_source != next_source then (
      let old_inner = owner.inner in
      let old_scope = owner.inner_scope in
      let fresh_scope = { valid = true; slot_head = -1 } in
      let fresh_inner =
        with_scope graph fresh_scope (fun () -> f next_source)
      in
      switch_dependency owner old_inner fresh_inner;
      retire_scope graph old_scope;
      owner.selected_source <- next_source;
      owner.inner <- fresh_inner;
      owner.inner_scope <- fresh_scope;
      owner.rollback_inner <- old_inner;
      owner.rollback_scope <- old_scope;
      owner.tentative_inner <- fresh_inner;
      push_capsule graph capsule);
    owner.inner.node.current
  in
  let bind_signal =
    make_node graph
      ~height:(1 + max source.node.height inner.node.height)
      ~dependencies:[| P source.node; P inner.node |]
      ~compute ~cutoff ~initial:inner.node.current
  in
  let owner =
    {
      bind_signal;
      source;
      selector = f;
      selected_source = source.node.current;
      inner;
      inner_scope = scope;
      rollback_inner = inner;
      rollback_scope = scope;
      tentative_inner = inner;
    }
  in
  owner_ref := Some owner;
  owner

let bind ?cutoff source ~f = (bind_owner ?cutoff source ~f).bind_signal
let bind_current owner = owner.inner
let bind_scope_valid owner = owner.inner_scope.valid

type ('key, 'data : value_or_null, 'output : value_or_null) keyed_child = {
  key : 'key;
  data : 'data var;
  output : 'output signal;
  scope : scope;
}

type keyed_event =
  | Keyed_detached of scope
  | Keyed_invalidated of scope
  | Keyed_attached of scope

type ('key, 'value) child_tree =
  | Child_empty
  | Child_branch of {
      height : int;
      left : ('key, 'value) child_tree;
      key : 'key;
      value : 'value;
      right : ('key, 'value) child_tree;
    }

let child_height = function
  | Child_empty -> 0
  | Child_branch branch -> branch.height

let child_make left key value right =
  Child_branch
    {
      height = 1 + max (child_height left) (child_height right);
      left;
      key;
      value;
      right;
    }

let child_balance left key value right =
  let left_height = child_height left in
  let right_height = child_height right in
  if left_height > right_height + 2 then
    match left with
    | Child_empty -> assert false
    | Child_branch l ->
        if child_height l.left >= child_height l.right then
          child_make l.left l.key l.value
            (child_make l.right key value right)
        else
          (match l.right with
          | Child_empty -> assert false
          | Child_branch lr ->
              child_make
                (child_make l.left l.key l.value lr.left)
                lr.key lr.value
                (child_make lr.right key value right))
  else if right_height > left_height + 2 then
    match right with
    | Child_empty -> assert false
    | Child_branch r ->
        if child_height r.right >= child_height r.left then
          child_make (child_make left key value r.left)
            r.key r.value r.right
        else
          (match r.left with
          | Child_empty -> assert false
          | Child_branch rl ->
              child_make
                (child_make left key value rl.left)
                rl.key rl.value
                (child_make rl.right r.key r.value r.right))
  else child_make left key value right

let rec child_find compare key = function
  | Child_empty -> None
  | Child_branch branch ->
      let order = compare key branch.key in
      if order = 0 then Some branch.value
      else if order < 0 then child_find compare key branch.left
      else child_find compare key branch.right

let rec child_add compare key value = function
  | Child_empty -> child_make Child_empty key value Child_empty
  | Child_branch branch as tree ->
      let order = compare key branch.key in
      if order = 0 then
        if value == branch.value then tree
        else child_make branch.left key value branch.right
      else if order < 0 then
        child_balance
          (child_add compare key value branch.left)
          branch.key branch.value branch.right
      else
        child_balance branch.left branch.key branch.value
          (child_add compare key value branch.right)

let rec child_min = function
  | Child_empty -> raise Not_found
  | Child_branch { left = Child_empty; key; value; _ } -> key, value
  | Child_branch branch -> child_min branch.left

let rec child_remove compare key = function
  | Child_empty -> Child_empty
  | Child_branch branch ->
      let order = compare key branch.key in
      if order < 0 then
        child_balance
          (child_remove compare key branch.left)
          branch.key branch.value branch.right
      else if order > 0 then
        child_balance branch.left branch.key branch.value
          (child_remove compare key branch.right)
      else
        match branch.left, branch.right with
        | Child_empty, right -> right
        | left, Child_empty -> left
        | left, right ->
            let successor_key, successor = child_min right in
            child_balance left successor_key successor
              (child_remove compare successor_key right)

let rec child_iter f = function
  | Child_empty -> ()
  | Child_branch branch ->
      child_iter f branch.left;
      f branch.value;
      child_iter f branch.right

type ('key, 'data : value_or_null, 'input : value_or_null,
      'output : value_or_null, 'output_map : value_or_null) keyed_owner = {
  keyed_signal : 'output_map signal;
  keyed_input : 'input signal;
  input_ops : ('key, 'data, 'input) input_ops;
  output_ops : ('key, 'output, 'output_map) output_ops;
  data_cutoff : 'data -> 'data -> bool;
  builder : key:'key -> data:'data signal -> 'output signal;
  mutable precommit : (unit -> unit) option;
  mutable event_recorder : keyed_event -> unit;
  mutable committed_input : 'input;
  mutable children :
    ('key, ('key, 'data, 'output) keyed_child) child_tree;
  mutable output_root : 'output_map;
  mutable candidate_children :
    ('key, ('key, 'data, 'output) keyed_child) child_tree;
  mutable candidate_output : 'output_map;
  mutable output_undo : 'output_map;
  mutable output_written_in : int;
}

let rec count_children acc = function
  | Child_empty -> acc
  | Child_branch branch ->
      count_children (count_children (acc + 1) branch.left) branch.right

let keyed_node_counts graph =
  let keyed_node_count = ref 0 in
  let committed_child_count = ref 0 in
  for slot = 0 to graph.slot_count - 1 do
    match slot_contents graph.slots.(slot) with
    | Some (P node) -> (
        match node.keyed_owner with
        | None -> ()
        | Some packed_owner ->
            let owner : (_, _, _, _, _) keyed_owner = Obj.obj packed_owner in
            if
              same_handle owner.keyed_signal.handle node.handle
              && validate_handle owner.keyed_signal
            then (
              incr keyed_node_count;
              committed_child_count :=
                count_children !committed_child_count owner.children))
    | None -> ()
  done;
  (!keyed_node_count, !committed_child_count)

let append_nodes_dot buffer graph ~only_necessary ~scope_label ~dot_state
    ~dot_dynamic_scopes =
  for slot = 0 to graph.slot_count - 1 do
    match slot_contents graph.slots.(slot) with
    | None -> ()
    | Some (P node) ->
        let internal_source =
          not (node_constant node) && Array.length node.dependencies = 0
        in
        if (not internal_source) && ((not only_necessary) || node_necessary node)
        then (
          let dependent_count = ref 0 in
          for candidate_slot = 0 to graph.slot_count - 1 do
            match slot_contents graph.slots.(candidate_slot) with
            | Some (P candidate) ->
                Array.iter
                  (fun (P dependency) ->
                    if same_handle dependency.handle node.handle then
                      incr dependent_count)
                  candidate.dependencies
            | None -> ()
          done;
          let owner_opt = node.keyed_owner in
          let keyed_extra =
            if Option.is_some owner_opt then
              match owner_opt with
              | Some owner_obj when dot_state ->
                  let owner : (_, _, _, _, _) keyed_owner =
                    Obj.obj owner_obj
                  in
                  let child_count = count_children 0 owner.children in
                  let base =
                    Printf.sprintf
                      " kind=keyed_mapi committed_children=%d requested_scope=%s"
                      child_count scope_label
                  in
                  if dot_dynamic_scopes then base ^ " scope_owner=s" ^ " :valid"
                  else base
              | Some _ when dot_state -> " kind=keyed_mapi"
              | Some _ -> " kind=keyed_mapi"
              | None -> " kind=keyed_mapi"
            else ""
          in
          Buffer.add_string buffer
            (Printf.sprintf "  signal_%d [label=\"signal_%d%s%s\"];\n" slot
               slot keyed_extra
               (if dot_state then
                  Printf.sprintf
                    " necessary=%b dirty=%b queued=%b dependencies=%d dependents=%d signal_id=s%d%s"
                    (node_necessary node)
                    (node_admitted node
                    || Array.exists
                         (fun (P dependency) -> node_admitted dependency)
                         node.dependencies)
                    (node.queued_in = graph.pass
                    || Array.exists
                         (fun (P dependency) ->
                           node_admitted dependency
                           || dependency.queued_in = graph.pass)
                         node.dependencies)
                    (Array.length node.dependencies) !dependent_count slot
                    (match node.scope with
                    | None -> ""
                    | Some scope ->
                        Printf.sprintf
                          " scope=%s scope_id=sc%d scope_owner=s%d scope_parent=root"
                          (if scope.valid then "valid" else "invalid")
                          scope.slot_head scope.slot_head)
                else ""));
          Array.iter
            (fun (P child) ->
              let child_internal =
                not (node_constant child) && Array.length child.dependencies = 0
              in
              if not child_internal then
                Buffer.add_string buffer
                  (Printf.sprintf "  signal_%d -> signal_%d;\n"
                     child.handle.slot slot))
            node.dependencies)
  done


let keyed_find owner key =
  child_find owner.input_ops.compare_key key owner.children

let keyed_owner ?(cutoff = ( == )) ?(data_cutoff = ( == ))
    ~(input : 'input signal) ~input_ops ~output_ops ~build () =
  let graph = input.graph in
  enable_change_listeners graph;
  let owner_ref = ref None in
  let stage_child_output owner key value =
    if owner.output_written_in <> graph.pass then (
      owner.output_undo <- owner.output_root;
      owner.output_written_in <- graph.pass;
      push_capsule graph
        {
          rollback_capsule =
            (fun () ->
              owner.output_root <- owner.output_undo;
              owner.output_written_in <- -1);
          cleanup_capsule = (fun () -> owner.output_written_in <- -1);
        });
    owner.output_root <-
      output_ops.set_output key value owner.output_root
  in
  let install_child_listener owner child =
    child.output.node.change_listeners <-
      (fun value -> stage_child_output owner child.key value)
      :: child.output.node.change_listeners
  in
  let attach_child owner child =
    add_dependent child.output.packed owner.keyed_signal.packed;
    if node_necessary owner.keyed_signal.node then activate child.output.packed;
    graph.work.topology_edits <- graph.work.topology_edits + 1
  in
  let detach_child owner child =
    remove_dependent child.output.packed owner.keyed_signal.packed;
    if node_necessary child.output.node then (
      graph.suppress_reclaim <- true;
      deactivate child.output.packed;
      graph.suppress_reclaim <- false);
    graph.work.topology_edits <- graph.work.topology_edits + 1
  in
  let reconcile owner next_input =
    bump_keyed_for owner.keyed_signal.graph `Reconciliation;
    graph.keyed_reconciliations_in_pass <-
      graph.keyed_reconciliations_in_pass + 1;
    let old_children = owner.children in
    let old_output = owner.output_root in
    owner.candidate_children <- owner.children;
    owner.candidate_output <- owner.output_root;
    let removed = ref [] in
    let added = ref [] in
    input_ops.iter_diff owner.committed_input next_input
      (fun key change ->
        match change with
        | Changed (_, data) -> (
            match keyed_find owner key with
            | None -> raise Stale_handle
            | Some child ->
                let published = child.data.signal.node.current in
                if not (owner.data_cutoff published data) then
                  set graph child.data data)
        | Left _ -> (
            match keyed_find owner key with
            | None -> ()
            | Some child ->
                removed := child :: !removed;
                owner.candidate_children <-
                  child_remove input_ops.compare_key key
                    owner.candidate_children;
                owner.candidate_output <-
                  output_ops.remove_output key owner.candidate_output)
        | Right data ->
            let scope = { valid = true; slot_head = -1 } in
            bump_keyed_for owner.keyed_signal.graph `Provisional_addition;
            let source = with_scope graph scope (fun () -> var graph data) in
            let output = with_scope graph scope (fun () -> build ~key ~data:(watch source)) in
            let child = { key; data = source; output; scope } in
            added := child :: !added;
            install_child_listener owner child;
            owner.candidate_children <-
              child_add input_ops.compare_key key child
                owner.candidate_children;
            owner.candidate_output <-
              output_ops.set_output key output.node.current
                owner.candidate_output);
    (match owner.precommit with
    | Some f ->
        owner.precommit <- None;
        f ()
    | None -> ());
    List.iter
      (fun (child : (_, _, _) keyed_child) ->
        detach_child owner child;
        owner.event_recorder (Keyed_detached child.scope);
        retire_scope graph child.scope;
        owner.event_recorder (Keyed_invalidated child.scope))
      !removed;
    List.iter
      (fun child ->
        attach_child owner child;
        owner.event_recorder (Keyed_attached child.scope))
      !added;
    owner.children <- owner.candidate_children;
    owner.output_root <- owner.candidate_output;
    let old_input = owner.committed_input in
    owner.committed_input <- next_input;
    push_capsule graph
      {
        rollback_capsule =
          (fun () ->
            enqueue owner.keyed_signal.packed;
            List.iter
              (fun child -> detach_child owner child)
              !added;
            List.iter
              (fun child -> attach_child owner child)
              !removed;
            owner.committed_input <- old_input;
            owner.children <- old_children;
            owner.output_root <- old_output);
        cleanup_capsule =
          (fun () ->
            List.iter
              (fun _ ->
                bump_keyed_for owner.keyed_signal.graph `Committed_addition)
              !added;
            List.iter
              (fun _ ->
                bump_keyed_for owner.keyed_signal.graph `Committed_removal)
              !removed;
            List.iter
              (fun (child : (_, _, _) keyed_child) ->
                child.scope.valid <- false)
              !removed);
      }
  in
  let compute () =
    let owner = Option.get !owner_ref in
    let next = input.node.current in
    if owner.committed_input != next then reconcile owner next;
    owner.output_root
  in
  let keyed_signal =
    make_node graph ~height:(input.node.height + 2)
      ~dependencies:[| P input.node |] ~compute ~cutoff
      ~initial:output_ops.empty_output
  in
  let owner =
    {
      keyed_signal;
      keyed_input = input;
      input_ops;
      output_ops;
      data_cutoff;
      builder = build;
      precommit = None;
      event_recorder = (fun _ -> ());
      committed_input = input_ops.empty_input;
      children = Child_empty;
      output_root = output_ops.empty_output;
      candidate_children = Child_empty;
      candidate_output = output_ops.empty_output;
      output_undo = output_ops.empty_output;
      output_written_in = -1;
    }
  in
  owner_ref := Some owner;
  owner.keyed_signal.node.keyed_owner <- Some (Obj.repr owner);
  keyed_signal.node.demand_listeners <-
    [
      (fun necessary ->
        child_iter
          (fun child ->
            if necessary then activate child.output.packed
            else deactivate child.output.packed)
          owner.children);
    ];
  (* Initial reconciliation is construction, not a transaction. *)
  input_ops.iter_diff input_ops.empty_input input.node.current
    (fun key -> function
      | Right data ->
          let scope = { valid = true; slot_head = -1 } in
          let source = with_scope graph scope (fun () -> var graph data) in
          let output =
            with_scope graph scope (fun () ->
                build ~key ~data:(watch source))
          in
          let child = { key; data = source; output; scope } in
          install_child_listener owner child;
          owner.children <-
            child_add input_ops.compare_key key child owner.children;
          owner.output_root <-
            output_ops.set_output key output.node.current owner.output_root;
          add_dependent output.packed keyed_signal.packed
      | Left _ | Changed _ -> ());
  owner.committed_input <- input.node.current;
  keyed_signal.node.current <- owner.output_root;
  keyed_signal.node.undo <- owner.output_root;
  owner

let keyed ?cutoff ?data_cutoff ~input ~input_ops ~output_ops ~build () =
  (keyed_owner ?cutoff ?data_cutoff ~input ~input_ops ~output_ops ~build ())
    .keyed_signal

let keyed_child owner key = keyed_find owner key
let set_keyed_event_recorder owner record = owner.event_recorder <- record
let set_keyed_precommit owner f = owner.precommit <- Some f
let keyed_scope_valid (child : (_, _, _) keyed_child) = child.scope.valid
let journal_high_water graph = graph.journal_high_water
let slot_count graph = graph.slot_count
let free_count graph = graph.free_length

type workload = {
  name : string;
  run_batch : int -> unit;
  check : unit -> unit;
}

let raw_scalar ?(cutoff = false) depth =
  let graph = create () in
  let source = var graph 0 in
  let base =
    if cutoff then map ~cutoff:Int.equal (fun _ -> 0) (watch source)
    else watch source
  in
  let rec loop n signal =
    if n = 0 then signal else loop (n - 1) (map (( + ) 1) signal)
  in
  let output = loop depth base in
  ignore (demand output);
  let next = ref 0 in
  {
    name =
      Printf.sprintf "%s.depth_%d"
        (if cutoff then "cutoff" else "changed") depth;
    run_batch =
      (fun count ->
        for _ = 1 to count do
          incr next;
          set graph source !next;
          stabilize_unit graph
        done);
    check =
      (fun () ->
        let expected = if cutoff then depth else !next + depth in
        if value output <> expected then failwith "raw scalar mismatch");
  }
