(* Selected issue-11 core.  This is a private, synchronous probe kernel. *)

type phase = Idle | Active | Cleanup_pending
type stabilization = Quiescent | Committed
type error = Defect of exn | Reentrant_stabilization

exception Stale_handle
exception Wrong_phase of phase
exception Pass_identity_exhausted
exception Generation_exhausted

type handle = { slot : int; generation : int }

type work = {
  mutable admissions : int;
  mutable claims : int;
  mutable evaluations : int;
  mutable dependency_edges : int;
  mutable propagation_edges : int;
  mutable topology_edits : int;
  mutable cleanup_visits : int;
  mutable rollback_visits : int;
  mutable verdict_steps : int;
}

type scope = {
  mutable valid : bool;
  mutable slot_head : int;
}

type 'a node = {
  graph : graph;
  handle : handle;
  mutable height : int;
  mutable current : 'a;
  mutable undo : 'a;
  mutable written_in : int;
  constant : bool;
  compute : unit -> 'a;
  cutoff : 'a -> 'a -> bool;
  mutable dependencies : packed array;
  mutable dependents : packed list;
  mutable necessary : bool;
  mutable demand : int;
  mutable queued_in : int;
  mutable queue_next : int;
  mutable admitted : bool;
  mutable reclaim_queued : bool;
  mutable change_listeners : ('a -> unit) list;
  mutable demand_listeners : (bool -> unit) list;
  scope_next : int;
  scope : scope option;
}

and packed = P : 'a node -> packed

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
  mutable running : bool;
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
  mutable admissions : int array;
  mutable admission_length : int;
  mutable current_scope : scope option;
  mutable pending_reclaims : handle array;
  mutable pending_reclaim_length : int;
  mutable suppress_reclaim : bool;
  mutable tombstones : handle array;
  mutable tombstone_length : int;
  work : work;
}

type 'a signal = {
  graph : graph;
  handle : handle;
  node : 'a node;
  packed : packed;
}

type 'a var = {
  signal : 'a signal;
  accepted : 'a ref;
  source_cutoff : 'a -> 'a -> bool;
}

type demand = packed

type 'a change = Left of 'a | Right of 'a | Changed of 'a * 'a

type ('key, 'data, 'map) input_ops = {
  empty_input : 'map;
  compare_key : 'key -> 'key -> int;
  iter_diff :
    'map -> 'map -> ('key -> 'data change -> unit) -> unit;
}

type ('key, 'value, 'map) output_ops = {
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
    cleanup_visits = 0;
    rollback_visits = 0;
    verdict_steps = 0;
  }

let create () =
  {
    phase = Idle;
    pass = 0;
    running = false;
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
    admissions = Array.make 8 0;
    admission_length = 0;
    current_scope = None;
    pending_reclaims = Array.make 16 { slot = -1; generation = -1 };
    pending_reclaim_length = 0;
    suppress_reclaim = false;
    tombstones = Array.make 16 { slot = -1; generation = -1 };
    tombstone_length = 0;
    work = empty_work ();
  }

let work graph = graph.work

let reset_work graph =
  let zero = empty_work () in
  graph.work.admissions <- zero.admissions;
  graph.work.claims <- zero.claims;
  graph.work.evaluations <- zero.evaluations;
  graph.work.dependency_edges <- zero.dependency_edges;
  graph.work.propagation_edges <- zero.propagation_edges;
  graph.work.topology_edits <- zero.topology_edits;
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
    Array.blit graph.heads 0 heads 0 (Array.length graph.heads);
    Array.blit graph.tails 0 tails 0 (Array.length graph.tails);
    graph.heads <- heads;
    graph.tails <- tails)

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
      node.handle = signal.handle
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
  if
    not
      (List.exists
         (fun (P candidate) -> candidate.handle = parent_handle)
         child.dependents)
  then child.dependents <- parent :: child.dependents

let remove_dependent child parent =
  let P child = child in
  let P parent = parent in
  child.dependents <-
    List.filter
      (fun (P candidate) -> candidate.handle <> parent.handle)
      child.dependents

let attach parent child =
  let P parent_node = parent in
  if
    not
      (Array.exists
         (fun (P candidate) -> candidate.handle = (let P c = child in c.handle))
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
           if candidate.handle = child_node.handle then rest else packed :: rest)
         parent_node.dependencies []);
  remove_dependent child parent;
  parent_node.graph.work.topology_edits <-
    parent_node.graph.work.topology_edits + 1

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
      constant;
      compute;
      cutoff;
      dependencies;
      dependents = [];
      necessary = false;
      demand = 0;
      queued_in = -1;
      queue_next = -1;
      admitted = false;
      reclaim_queued = false;
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
  Array.iter (fun child -> add_dependent child (P node)) dependencies;
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
  if node.necessary && node.queued_in <> graph.pass then (
    node.queued_in <- graph.pass;
    node.queue_next <- -1;
    ensure_height graph node.height;
    if graph.tails.(node.height) = -1 then (
      graph.heads.(node.height) <- node.handle.slot;
      graph.tails.(node.height) <- node.handle.slot)
    else (
      let P tail = resolve_slot graph graph.tails.(node.height) in
      tail.queue_next <- node.handle.slot;
      graph.tails.(node.height) <- node.handle.slot);
    graph.highest <- max graph.highest node.height)

let retain_admission graph node =
  if not node.admitted then (
    if graph.admission_length = Array.length graph.admissions then
      graph.admissions <- grow_int graph.admissions;
    node.admitted <- true;
    graph.admissions.(graph.admission_length) <- node.handle.slot;
    graph.admission_length <- graph.admission_length + 1)

let rec activate (P node as packed) =
  node.demand <- node.demand + 1;
  if not node.necessary then (
    let slot = node.graph.slots.(node.handle.slot) in
    if slot.strong = None then set_slot_contents slot (Some packed);
    node.reclaim_queued <- false;
    node.necessary <- true;
    Array.iter
      (fun dependency ->
        add_dependent dependency packed;
        activate dependency)
      node.dependencies;
    List.iter (fun notify -> notify true) node.demand_listeners;
    if Array.length node.dependencies = 0 && not node.constant then (
      retain_admission node.graph node;
      enqueue packed))

let demand signal =
  if not (validate_handle signal) then raise Stale_handle;
  activate signal.packed;
  signal.packed

let rec deactivate (P node as packed) =
  if node.demand > 0 then node.demand <- node.demand - 1;
  if node.necessary && node.demand = 0
     &&
     not
       (List.exists (fun (P parent) -> parent.necessary) node.dependents)
  then (
    node.necessary <- false;
    if (not node.graph.suppress_reclaim) && not node.reclaim_queued then (
      node.reclaim_queued <- true;
      let graph = node.graph in
      if graph.pending_reclaim_length = Array.length graph.pending_reclaims then (
        let next =
          Array.make (2 * Array.length graph.pending_reclaims)
            { slot = -1; generation = -1 }
        in
        Array.blit graph.pending_reclaims 0 next 0 graph.pending_reclaim_length;
        graph.pending_reclaims <- next);
      graph.pending_reclaims.(graph.pending_reclaim_length) <- node.handle;
      graph.pending_reclaim_length <- graph.pending_reclaim_length + 1);
    List.iter (fun notify -> notify false) node.demand_listeners;
    Array.iter
      (fun dependency ->
        remove_dependent dependency packed;
        deactivate dependency)
      node.dependencies;
    if not node.graph.suppress_reclaim then
      weaken_slot node.graph.slots.(node.handle.slot) packed)

let release demand = deactivate demand

let value signal =
  if not (validate_handle signal) then raise Stale_handle;
  signal.node.current

let record_first_write (node : 'a node) =
  let graph = node.graph in
  if node.written_in <> graph.pass then (
    if graph.journal_length = Array.length graph.journal then
      graph.journal <- grow_int graph.journal;
    node.undo <- node.current;
    node.written_in <- graph.pass;
    graph.journal.(graph.journal_length) <- node.handle.slot;
    graph.journal_length <- graph.journal_length + 1;
    graph.journal_high_water <-
      max graph.journal_high_water graph.journal_length)

let set graph variable candidate =
  if variable.signal.graph != graph then
    invalid_arg "selected_core: graph mismatch";
  graph.work.admissions <- graph.work.admissions + 1;
  if not (variable.source_cutoff !(variable.accepted) candidate) then (
    variable.accepted := candidate;
    retain_admission graph variable.signal.node;
    enqueue variable.signal.packed)

let rec evaluate (P node as packed) =
  let graph = node.graph in
  graph.work.claims <- graph.work.claims + 1;
  let changed =
    if node.constant then false
    else (
      if Array.length node.dependencies > 0 then (
      graph.work.evaluations <- graph.work.evaluations + 1;
      graph.work.dependency_edges <-
        graph.work.dependency_edges + Array.length node.dependencies);
      let next = node.compute () in
      if node.cutoff node.current next then false
      else (
        record_first_write node;
        node.current <- next;
        List.iter (fun notify -> notify next) node.change_listeners;
        true))
  in
  (if changed then
    match node.dependents with
    | [ (P parent_node as parent) ]
      when parent_node.necessary
           && Array.length parent_node.dependencies = 1
           && parent_node.height = node.height + 1 ->
        graph.work.propagation_edges <- graph.work.propagation_edges + 1;
        ignore (evaluate parent)
    | parents ->
        List.iter
          (fun parent ->
            let P parent_node = parent in
            graph.work.propagation_edges <- graph.work.propagation_edges + 1;
            if parent_node.necessary then enqueue parent)
          parents);
  ignore packed;
  changed

let pop graph height =
  let slot = graph.heads.(height) in
  if slot = -1 then None
  else
    let resolved = slot_contents graph.slots.(slot) in
    match resolved with
    | None -> raise Stale_handle
    | Some (P node) ->
        graph.heads.(height) <- node.queue_next;
        if node.queue_next = -1 then graph.tails.(height) <- -1;
        node.queue_next <- -1;
        resolved

let rec drain_from graph height changed =
  if height > graph.highest then changed
  else
    match pop graph height with
    | None -> drain_from graph (height + 1) changed
    | Some node ->
      (* Dynamic child admissions can be below the current owner height. *)
      drain_from graph 0 (evaluate node || changed)

let drain graph = drain_from graph 0 false

let begin_pass graph =
  if graph.phase <> Idle then raise (Wrong_phase graph.phase);
  if graph.pass = max_int then raise Pass_identity_exhausted;
  graph.phase <- Active;
  graph.action_length <- 0;
  graph.capsule_length <- 0;
  graph.quarantine_length <- 0

let retire_packed graph (P node as packed) =
  if graph.phase <> Active then raise (Wrong_phase graph.phase);
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
  graph.highest <- -1

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
          | Some (P node) when node.necessary ->
              node.reclaim_queued <- false;
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

let clear_admissions graph =
  for index = 0 to graph.admission_length - 1 do
    match slot_contents graph.slots.(graph.admissions.(index)) with
    | Some (P node) ->
        node.admitted <- false
    | None -> ()
  done;
  graph.admission_length <- 0

let run_stabilization graph checkpoint =
  if graph.running then raise Exit
  else
    graph.running <- true;
    match
      begin_pass graph;
      let changed = drain graph in
      Option.iter (fun checkpoint -> checkpoint ()) checkpoint;
      clear_queues graph;
      commit graph;
      clear_admissions graph;
      if graph.phase = Cleanup_pending then cleanup graph;
      graph.running <- false;
      changed
    with
    | changed -> changed
    | exception exn ->
        rollback graph;
        graph.running <- false;
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
    if owner.bind_signal.node.necessary then (
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

type ('key, 'data, 'output) keyed_child = {
  key : 'key;
  data : 'data var;
  output : 'output signal;
  scope : scope;
}

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

type ('key, 'data, 'input, 'output, 'output_map) keyed_owner = {
  keyed_signal : 'output_map signal;
  keyed_input : 'input signal;
  input_ops : ('key, 'data, 'input) input_ops;
  output_ops : ('key, 'output, 'output_map) output_ops;
  builder : key:'key -> data:'data signal -> 'output signal;
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

let keyed_find owner key =
  child_find owner.input_ops.compare_key key owner.children

let keyed_owner ?(cutoff = ( == )) ~(input : 'input signal) ~input_ops
    ~output_ops ~build () =
  let graph = input.graph in
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
    if owner.keyed_signal.node.necessary then activate child.output.packed;
    graph.work.topology_edits <- graph.work.topology_edits + 1
  in
  let detach_child owner child =
    remove_dependent child.output.packed owner.keyed_signal.packed;
    if child.output.node.necessary then (
      graph.suppress_reclaim <- true;
      deactivate child.output.packed;
      graph.suppress_reclaim <- false);
    graph.work.topology_edits <- graph.work.topology_edits + 1
  in
  let reconcile owner next_input =
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
                set graph child.data data;
                ())
        | Left _ -> (
            match keyed_find owner key with
            | None -> ()
            | Some child ->
                removed := child :: !removed;
                detach_child owner child;
                owner.candidate_children <-
                  child_remove input_ops.compare_key key
                    owner.candidate_children;
                owner.candidate_output <-
                  output_ops.remove_output key owner.candidate_output)
        | Right data ->
            let scope = { valid = true; slot_head = -1 } in
            let source = with_scope graph scope (fun () -> var graph data) in
            let output =
              with_scope graph scope (fun () ->
                  build ~key ~data:(watch source))
            in
            let child = { key; data = source; output; scope } in
            added := child :: !added;
            install_child_listener owner child;
            attach_child owner child;
            owner.candidate_children <-
              child_add input_ops.compare_key key child
                owner.candidate_children;
            owner.candidate_output <-
              output_ops.set_output key output.node.current
                owner.candidate_output);
    List.iter
      (fun (child : (_, _, _) keyed_child) ->
        retire_scope graph child.scope)
      !removed;
    owner.children <- owner.candidate_children;
    owner.output_root <- owner.candidate_output;
    let old_input = owner.committed_input in
    owner.committed_input <- next_input;
    push_capsule graph
      {
        rollback_capsule =
          (fun () ->
            List.iter
              (fun child -> detach_child owner child)
              !added;
            List.iter
              (fun child ->
                add_dependent child.output.packed owner.keyed_signal.packed;
                graph.work.topology_edits <- graph.work.topology_edits + 1)
              !removed;
            owner.committed_input <- old_input;
            owner.children <- old_children;
            owner.output_root <- old_output);
        cleanup_capsule =
          (fun () ->
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
      builder = build;
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

let keyed ?cutoff ~input ~input_ops ~output_ops ~build () =
  (keyed_owner ?cutoff ~input ~input_ops ~output_ops ~build ()).keyed_signal

let keyed_child owner key = keyed_find owner key
let keyed_scope_valid (child : (_, _, _) keyed_child) = child.scope.valid
let journal_high_water graph = graph.journal_high_water
let phase graph = graph.phase
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
