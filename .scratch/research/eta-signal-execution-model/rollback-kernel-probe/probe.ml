(* PROTOTYPE: This executable compares rollback representations on the accepted
   synchronous propagation kernel. It is not production Signal code. *)

exception Injected_failure

type stabilization = Quiescent | Committed

type error =
  | Defect of exn
  | Reentrant_stabilization

type counts = {
  mutable admissions : int;
  mutable claims : int;
  mutable dependency_edges : int;
  mutable propagation_edges : int;
  mutable evaluations : int;
  mutable cutoffs : int;
}

module type MODE = sig
  type state

  val create : int -> state
  val written_at : state -> int
  val read : state -> pass:int -> published:int -> int
  val write :
    state -> pass:int -> published:int -> candidate:int -> int
  val commit : state -> published:int -> int
  val rollback : state -> published:int -> int
  val commit_walk : bool
  val rollback_walk : bool
  val clear_slots : bool
end

module Make (Mode : MODE) = struct
  type nonrec stabilization = stabilization
  type nonrec error = error
  type nonrec counts = counts

  type node = {
    graph : graph;
    height : int;
    children : node array;
    mutable parents : node array;
    compute : unit -> int;
    cutoff : int -> int -> bool;
    mutable value : int;
    rollback : Mode.state;
    mutable necessary : bool;
    mutable queued_at : int;
    mutable queue_next : node option;
    mutable admitted : bool;
  }

  and graph = {
    mutable pass : int;
    mutable running : bool;
    mutable highest : int;
    mutable heads : node option array;
    mutable tails : node option array;
    mutable touched : Obj.t array;
    mutable touched_length : int;
    mutable touched_high_water : int;
    mutable admitted_sources : Obj.t array;
    mutable admitted_length : int;
    counts : counts;
  }

  type signal = node
  type var = { accepted : int ref; watch : node }
  type demand = node

  let create () =
    {
      pass = 0;
      running = false;
      highest = -1;
      heads = Array.make 4 None;
      tails = Array.make 4 None;
      touched = Array.make 16 (Obj.repr 0);
      touched_length = 0;
      touched_high_water = 0;
      admitted_sources = Array.make 4 (Obj.repr 0);
      admitted_length = 0;
      counts =
        {
          admissions = 0;
          claims = 0;
          dependency_edges = 0;
          propagation_edges = 0;
          evaluations = 0;
          cutoffs = 0;
        };
    }

  let reset_counts t =
    t.counts.admissions <- 0;
    t.counts.claims <- 0;
    t.counts.dependency_edges <- 0;
    t.counts.propagation_edges <- 0;
    t.counts.evaluations <- 0;
    t.counts.cutoffs <- 0

  let ensure_height graph height =
    if height >= Array.length graph.heads then (
      let length = ref (Array.length graph.heads) in
      while height >= !length do
        length := !length * 2
      done;
      let heads = Array.make !length None in
      let tails = Array.make !length None in
      Array.blit graph.heads 0 heads 0 (Array.length graph.heads);
      Array.blit graph.tails 0 tails 0 (Array.length graph.tails);
      graph.heads <- heads;
      graph.tails <- tails)

  let grow buffer =
    let next = Array.make (Array.length buffer * 2) (Obj.repr 0) in
    Array.blit buffer 0 next 0 (Array.length buffer);
    next

  let touch node =
    let graph = node.graph in
    if Mode.written_at node.rollback <> graph.pass then (
      if graph.touched_length = Array.length graph.touched then
        graph.touched <- grow graph.touched;
      graph.touched.(graph.touched_length) <- Obj.repr node;
      graph.touched_length <- graph.touched_length + 1;
      if graph.touched_length > graph.touched_high_water then
        graph.touched_high_water <- graph.touched_length)

  let add_parent child parent =
    let length = Array.length child.parents in
    let parents = Array.make (length + 1) parent in
    Array.blit child.parents 0 parents 0 length;
    child.parents <- parents

  let read node =
    Mode.read node.rollback ~pass:node.graph.pass ~published:node.value

  let make_node graph ~height ~children ~compute ~cutoff ~value =
    ensure_height graph height;
    let node =
      {
        graph;
        height;
        children;
        parents = [||];
        compute;
        cutoff;
        value;
        rollback = Mode.create value;
        necessary = false;
        queued_at = -1;
        queue_next = None;
        admitted = false;
      }
    in
    Array.iter (fun child -> add_parent child node) children;
    node

  let var graph value =
    let accepted = ref value in
    let watch =
      make_node graph ~height:0 ~children:[||]
        ~compute:(fun () -> !accepted)
        ~cutoff:(fun published candidate -> published == candidate)
        ~value
    in
    { accepted; watch }

  let watch var = var.watch

  let const graph value =
    make_node graph ~height:0 ~children:[||] ~compute:(fun () -> value)
      ~cutoff:(fun published candidate -> published == candidate) ~value

  let map ?(cutoff = ( == )) f child =
    let graph = child.graph in
    let initial = f child.value in
    make_node graph ~height:(child.height + 1) ~children:[| child |]
      ~compute:(fun () -> f (read child)) ~cutoff ~value:initial

  let map2 ?(cutoff = ( == )) f left right =
    if left.graph != right.graph then invalid_arg "graph mismatch";
    let graph = left.graph in
    let height = max left.height right.height + 1 in
    let initial = f left.value right.value in
    make_node graph ~height ~children:[| left; right |]
      ~compute:(fun () -> f (read left) (read right)) ~cutoff ~value:initial

  let enqueue node =
    let graph = node.graph in
    if node.necessary && node.queued_at <> graph.pass then (
      node.queued_at <- graph.pass;
      node.queue_next <- None;
      let height = node.height in
      match graph.tails.(height) with
      | None ->
          graph.heads.(height) <- Some node;
          graph.tails.(height) <- Some node;
          if height > graph.highest then graph.highest <- height
      | Some tail ->
          tail.queue_next <- Some node;
          graph.tails.(height) <- Some node;
          if height > graph.highest then graph.highest <- height)

  let retain_admission node =
    let graph = node.graph in
    if not node.admitted then (
      if graph.admitted_length = Array.length graph.admitted_sources then
        graph.admitted_sources <- grow graph.admitted_sources;
      node.admitted <- true;
      graph.admitted_sources.(graph.admitted_length) <- Obj.repr node;
      graph.admitted_length <- graph.admitted_length + 1)

  let set graph var value =
    if var.watch.graph != graph then invalid_arg "graph mismatch";
    graph.counts.admissions <- graph.counts.admissions + 1;
    if !(var.accepted) != value then (
      var.accepted := value;
      retain_admission var.watch;
      enqueue var.watch)

  let rec activate node =
    if not node.necessary then (
      node.necessary <- true;
      Array.iter activate node.children;
      if Array.length node.children = 0 then (
        retain_admission node;
        enqueue node))

  let demand node =
    activate node;
    node

  let release node =
    let rec deactivate node =
      if node.necessary then (
        node.necessary <- false;
        Array.iter
          (fun child ->
            let retained =
              Array.exists (fun parent -> parent.necessary) child.parents
            in
            if not retained then deactivate child)
          node.children)
    in
    deactivate node

  let pop graph height =
    match graph.heads.(height) with
    | None -> None
    | Some node ->
        graph.heads.(height) <- node.queue_next;
        if graph.heads.(height) = None then graph.tails.(height) <- None;
        node.queue_next <- None;
        Some node

  let write node candidate =
    touch node;
    node.value <-
      Mode.write node.rollback ~pass:node.graph.pass ~published:node.value
        ~candidate

  let rec recompute node =
    let graph = node.graph in
    graph.counts.claims <- graph.counts.claims + 1;
    let candidate = node.compute () in
    if node.height > 0 then (
      graph.counts.evaluations <- graph.counts.evaluations + 1;
      graph.counts.cutoffs <- graph.counts.cutoffs + 1;
      graph.counts.dependency_edges <-
        graph.counts.dependency_edges + Array.length node.children);
    if node.cutoff node.value candidate then false
    else (
      write node candidate;
      for index = 0 to Array.length node.parents - 1 do
        let parent = node.parents.(index) in
        graph.counts.propagation_edges <-
          graph.counts.propagation_edges + 1;
        if Array.length node.parents = 1
           && Array.length parent.children = 1
           && parent.height = node.height + 1
        then ignore (recompute parent)
        else enqueue parent
      done;
      true)

  let clear_touched graph ~publish ~restore =
    if restore then
      for index = graph.touched_length - 1 downto 0 do
        let node : node = Obj.obj graph.touched.(index) in
        node.value <- Mode.rollback node.rollback ~published:node.value;
        if Mode.clear_slots then graph.touched.(index) <- Obj.repr 0
      done
    else
      for index = 0 to graph.touched_length - 1 do
        let node : node = Obj.obj graph.touched.(index) in
        if publish then
          node.value <- Mode.commit node.rollback ~published:node.value
        else ignore (Mode.commit node.rollback ~published:node.value);
        if Mode.clear_slots then graph.touched.(index) <- Obj.repr 0
      done;
    graph.touched_length <- 0

  let drain_frontier graph =
    for height = 0 to graph.highest do
      let rec drain () =
        match pop graph height with
        | None -> ()
        | Some node ->
            node.queued_at <- -1;
            drain ()
      in
      drain ()
    done;
    graph.highest <- -1

  let clear_admissions graph =
    for index = 0 to graph.admitted_length - 1 do
      let node : node = Obj.obj graph.admitted_sources.(index) in
      node.admitted <- false;
      graph.admitted_sources.(index) <- Obj.repr 0
    done;
    graph.admitted_length <- 0

  let replay_admissions graph =
    for index = 0 to graph.admitted_length - 1 do
      let node : node = Obj.obj graph.admitted_sources.(index) in
      enqueue node
    done

  let[@inline always] stabilize graph =
    if graph.running then Error Reentrant_stabilization
    else (
      graph.running <- true;
      let rec drain height changed =
        if height > graph.highest then changed
        else
          match pop graph height with
          | None -> drain (height + 1) changed
          | Some node -> drain height (recompute node || changed)
      in
      match drain 0 false with
      | changed ->
          graph.highest <- -1;
          if Mode.commit_walk then
            clear_touched graph ~publish:true ~restore:false
          else graph.touched_length <- 0;
          clear_admissions graph;
          graph.pass <- graph.pass + 1;
          graph.running <- false;
          Ok (if changed then Committed else Quiescent)
      | exception exn ->
          if Mode.rollback_walk then
            clear_touched graph ~publish:false ~restore:true
          else graph.touched_length <- 0;
          drain_frontier graph;
          graph.pass <- graph.pass + 1;
          replay_admissions graph;
          graph.running <- false;
          Error (Defect exn))

  let value node = node.value
  let var_value var = !(var.accepted)
  let counts graph = graph.counts
  let touched_length graph = graph.touched_length
  let touched_high_water graph = graph.touched_high_water

  let touched_slot_is graph index node =
    index < Array.length graph.touched
    && Obj.repr node == graph.touched.(index)
end

module R1 = Make (struct
  type state = {
    mutable prev : int;
    mutable written_at : int;
  }

  let create value = { prev = value; written_at = -1 }
  let written_at state = state.written_at
  let read _state ~pass:_ ~published = published

  let write state ~pass ~published ~candidate =
    if state.written_at <> pass then state.prev <- published;
    state.written_at <- pass;
    candidate

  let commit state ~published =
    state.written_at <- -1;
    published

  let rollback state ~published:_ =
    state.written_at <- -1;
    state.prev

  let commit_walk = true
  let rollback_walk = true
  let clear_slots = true
end)

module R2 = Make (struct
  type state = {
    mutable candidate : int;
    mutable candidate_pass : int;
  }

  let create value = { candidate = value; candidate_pass = -1 }
  let written_at state = state.candidate_pass

  let read state ~pass ~published =
    if state.candidate_pass = pass then state.candidate else published

  let write state ~pass ~published ~candidate =
    state.candidate <- candidate;
    state.candidate_pass <- pass;
    published

  let commit state ~published:_ =
    state.candidate_pass <- -1;
    state.candidate

  let rollback _state ~published = published
  let commit_walk = true
  let rollback_walk = false
  let clear_slots = true
end)

module R1b = Make (struct
  type state = {
    mutable prev : int;
    mutable written_at : int;
  }

  let create value = { prev = value; written_at = -1 }
  let written_at state = state.written_at
  let read _state ~pass:_ ~published = published

  let write state ~pass ~published ~candidate =
    if state.written_at <> pass then state.prev <- published;
    state.written_at <- pass;
    candidate

  let commit _state ~published = published

  let rollback state ~published:_ =
    state.written_at <- -1;
    state.prev

  let commit_walk = false
  let rollback_walk = true
  let clear_slots = false
end)

module R1w = Make (struct
  type state = {
    mutable prev : int;
    mutable written_at : int;
  }

  let create value = { prev = value; written_at = -1 }
  let written_at state = state.written_at
  let read _state ~pass:_ ~published = published

  let write state ~pass ~published ~candidate =
    if state.written_at <> pass then state.prev <- published;
    state.written_at <- pass;
    candidate

  let commit state ~published =
    state.written_at <- -1;
    published

  let rollback state ~published:_ =
    state.written_at <- -1;
    state.prev

  let commit_walk = true
  let rollback_walk = true
  let clear_slots = false
end)

module R1m = struct
  type nonrec stabilization = stabilization
  type nonrec error = error
  type nonrec counts = counts

  type node = {
    graph : graph;
    height : int;
    children : node array;
    mutable parents : node array;
    compute : unit -> int;
    cutoff : int -> int -> bool;
    mutable value : int;
    mutable prev : int;
    mutable written_at : int;
    mutable necessary : bool;
    mutable queued_at : int;
    mutable queue_next : node option;
    mutable admitted : bool;
  }

  and graph = {
    mutable pass : int;
    mutable running : bool;
    mutable highest : int;
    mutable heads : node option array;
    mutable tails : node option array;
    mutable touched : Obj.t array;
    mutable touched_length : int;
    mutable touched_high_water : int;
    mutable admitted_sources : Obj.t array;
    mutable admitted_length : int;
    counts : counts;
  }

  type signal = node
  type var = { accepted : int ref; watch : node }
  type demand = node

  let create () =
    {
      pass = 0;
      running = false;
      highest = -1;
      heads = Array.make 4 None;
      tails = Array.make 4 None;
      touched = Array.make 16 (Obj.repr 0);
      touched_length = 0;
      touched_high_water = 0;
      admitted_sources = Array.make 4 (Obj.repr 0);
      admitted_length = 0;
      counts =
        {
          admissions = 0;
          claims = 0;
          dependency_edges = 0;
          propagation_edges = 0;
          evaluations = 0;
          cutoffs = 0;
        };
    }

  let reset_counts graph =
    graph.counts.admissions <- 0;
    graph.counts.claims <- 0;
    graph.counts.dependency_edges <- 0;
    graph.counts.propagation_edges <- 0;
    graph.counts.evaluations <- 0;
    graph.counts.cutoffs <- 0

  let grow buffer =
    let next = Array.make (Array.length buffer * 2) (Obj.repr 0) in
    Array.blit buffer 0 next 0 (Array.length buffer);
    next

  let ensure_height graph height =
    if height >= Array.length graph.heads then (
      let length = ref (Array.length graph.heads) in
      while height >= !length do
        length := !length * 2
      done;
      let heads = Array.make !length None in
      let tails = Array.make !length None in
      Array.blit graph.heads 0 heads 0 (Array.length graph.heads);
      Array.blit graph.tails 0 tails 0 (Array.length graph.tails);
      graph.heads <- heads;
      graph.tails <- tails)

  let add_parent child parent =
    let length = Array.length child.parents in
    let parents = Array.make (length + 1) parent in
    Array.blit child.parents 0 parents 0 length;
    child.parents <- parents

  let make_node graph ~height ~children ~compute ~cutoff ~value =
    ensure_height graph height;
    let node =
      {
        graph;
        height;
        children;
        parents = [||];
        compute;
        cutoff;
        value;
        prev = value;
        written_at = -1;
        necessary = false;
        queued_at = -1;
        queue_next = None;
        admitted = false;
      }
    in
    Array.iter (fun child -> add_parent child node) children;
    node

  let var graph value =
    let accepted = ref value in
    let watch =
      make_node graph ~height:0 ~children:[||]
        ~compute:(fun () -> !accepted)
        ~cutoff:(fun published candidate -> published == candidate)
        ~value
    in
    { accepted; watch }

  let watch var = var.watch

  let const graph value =
    make_node graph ~height:0 ~children:[||] ~compute:(fun () -> value)
      ~cutoff:(fun published candidate -> published == candidate) ~value

  let map ?(cutoff = ( == )) f child =
    make_node child.graph ~height:(child.height + 1) ~children:[| child |]
      ~compute:(fun () -> f child.value) ~cutoff ~value:(f child.value)

  let map2 ?(cutoff = ( == )) f left right =
    if left.graph != right.graph then invalid_arg "graph mismatch";
    make_node left.graph ~height:(max left.height right.height + 1)
      ~children:[| left; right |]
      ~compute:(fun () -> f left.value right.value) ~cutoff
      ~value:(f left.value right.value)

  let enqueue node =
    let graph = node.graph in
    if node.necessary && node.queued_at <> graph.pass then (
      node.queued_at <- graph.pass;
      node.queue_next <- None;
      match graph.tails.(node.height) with
      | None ->
          graph.heads.(node.height) <- Some node;
          graph.tails.(node.height) <- Some node;
          if node.height > graph.highest then graph.highest <- node.height
      | Some tail ->
          tail.queue_next <- Some node;
          graph.tails.(node.height) <- Some node;
          if node.height > graph.highest then graph.highest <- node.height)

  let retain_admission node =
    let graph = node.graph in
    if not node.admitted then (
      if graph.admitted_length = Array.length graph.admitted_sources then
        graph.admitted_sources <- grow graph.admitted_sources;
      node.admitted <- true;
      graph.admitted_sources.(graph.admitted_length) <- Obj.repr node;
      graph.admitted_length <- graph.admitted_length + 1)

  let set graph var value =
    if var.watch.graph != graph then invalid_arg "graph mismatch";
    graph.counts.admissions <- graph.counts.admissions + 1;
    if !(var.accepted) != value then (
      var.accepted := value;
      retain_admission var.watch;
      enqueue var.watch)

  let rec activate node =
    if not node.necessary then (
      node.necessary <- true;
      Array.iter activate node.children;
      if Array.length node.children = 0 then (
        retain_admission node;
        enqueue node))

  let demand node =
    activate node;
    node

  let release node =
    let rec deactivate node =
      if node.necessary then (
        node.necessary <- false;
        Array.iter
          (fun child ->
            if not (Array.exists (fun parent -> parent.necessary) child.parents)
            then deactivate child)
          node.children)
    in
    deactivate node

  let pop graph height =
    match graph.heads.(height) with
    | None -> None
    | Some node ->
        graph.heads.(height) <- node.queue_next;
        if graph.heads.(height) = None then graph.tails.(height) <- None;
        node.queue_next <- None;
        Some node

  let touch node =
    let graph = node.graph in
    if node.written_at <> graph.pass then (
      if graph.touched_length = Array.length graph.touched then
        graph.touched <- grow graph.touched;
      node.prev <- node.value;
      node.written_at <- graph.pass;
      graph.touched.(graph.touched_length) <- Obj.repr node;
      graph.touched_length <- graph.touched_length + 1;
      if graph.touched_length > graph.touched_high_water then
        graph.touched_high_water <- graph.touched_length)

  let rec recompute node =
    let graph = node.graph in
    graph.counts.claims <- graph.counts.claims + 1;
    let candidate = node.compute () in
    if node.height > 0 then (
      graph.counts.evaluations <- graph.counts.evaluations + 1;
      graph.counts.cutoffs <- graph.counts.cutoffs + 1;
      graph.counts.dependency_edges <-
        graph.counts.dependency_edges + Array.length node.children);
    if node.cutoff node.value candidate then false
    else (
      touch node;
      node.value <- candidate;
      for index = 0 to Array.length node.parents - 1 do
        let parent = node.parents.(index) in
        graph.counts.propagation_edges <-
          graph.counts.propagation_edges + 1;
        if Array.length node.parents = 1
           && Array.length parent.children = 1
           && parent.height = node.height + 1
        then ignore (recompute parent)
        else enqueue parent
      done;
      true)

  let rollback graph =
    for index = graph.touched_length - 1 downto 0 do
      let node : node = Obj.obj graph.touched.(index) in
      node.value <- node.prev;
      node.written_at <- -1
    done;
    graph.touched_length <- 0

  let drain_frontier graph =
    for height = 0 to graph.highest do
      let rec loop () =
        match pop graph height with
        | None -> ()
        | Some node ->
            node.queued_at <- -1;
            loop ()
      in
      loop ()
    done;
    graph.highest <- -1

  let clear_admissions graph =
    for index = 0 to graph.admitted_length - 1 do
      let node : node = Obj.obj graph.admitted_sources.(index) in
      node.admitted <- false;
      graph.admitted_sources.(index) <- Obj.repr 0
    done;
    graph.admitted_length <- 0

  let replay_admissions graph =
    for index = 0 to graph.admitted_length - 1 do
      let node : node = Obj.obj graph.admitted_sources.(index) in
      enqueue node
    done

  let[@inline always] stabilize graph =
    if graph.running then Error Reentrant_stabilization
    else (
      graph.running <- true;
      let rec drain height changed =
        if height > graph.highest then changed
        else
          match pop graph height with
          | None -> drain (height + 1) changed
          | Some node -> drain height (recompute node || changed)
      in
      match drain 0 false with
      | changed ->
          graph.highest <- -1;
          graph.touched_length <- 0;
          clear_admissions graph;
          graph.pass <- graph.pass + 1;
          graph.running <- false;
          Ok (if changed then Committed else Quiescent)
      | exception exn ->
          rollback graph;
          drain_frontier graph;
          graph.pass <- graph.pass + 1;
          replay_admissions graph;
          graph.running <- false;
          Error (Defect exn))

  let value node = node.value
  let var_value var = !(var.accepted)
  let counts graph = graph.counts
  let touched_length graph = graph.touched_length
  let touched_high_water graph = graph.touched_high_water

  let touched_slot_is graph index node =
    index < Array.length graph.touched
    && Obj.repr node == graph.touched.(index)
end


module R1a = struct
  type nonrec stabilization = stabilization
  type nonrec error = error
  type nonrec counts = counts

  type node = {
    graph : graph;
    height : int;
    children : node array;
    mutable parents : node array;
    compute : unit -> int;
    cutoff : int -> int -> bool;
    mutable value : int;
    mutable prev : int;
    mutable written_at : int;
    mutable necessary : bool;
    mutable queued_at : int;
    mutable queue_next : node option;
    mutable admitted : bool;
  }

  and graph = {
    mutable pass : int;
    mutable running : bool;
    mutable highest : int;
    mutable heads : node option array;
    mutable tails : node option array;
    mutable touched : Obj.t array;
    mutable touched_length : int;
    mutable touched_high_water : int;
    mutable admitted_sources : Obj.t array;
    mutable admitted_length : int;
    counts : counts;
  }

  type signal = node
  type var = { accepted : int ref; watch : node }
  type demand = node

  let create () =
    {
      pass = 0;
      running = false;
      highest = -1;
      heads = Array.make 4 None;
      tails = Array.make 4 None;
      touched = Array.make 16 (Obj.repr 0);
      touched_length = 0;
      touched_high_water = 0;
      admitted_sources = Array.make 4 (Obj.repr 0);
      admitted_length = 0;
      counts =
        {
          admissions = 0;
          claims = 0;
          dependency_edges = 0;
          propagation_edges = 0;
          evaluations = 0;
          cutoffs = 0;
        };
    }

  let reset_counts graph =
    graph.counts.admissions <- 0;
    graph.counts.claims <- 0;
    graph.counts.dependency_edges <- 0;
    graph.counts.propagation_edges <- 0;
    graph.counts.evaluations <- 0;
    graph.counts.cutoffs <- 0

  let grow buffer =
    let next = Array.make (Array.length buffer * 2) (Obj.repr 0) in
    Array.blit buffer 0 next 0 (Array.length buffer);
    next

  let ensure_height graph height =
    if height >= Array.length graph.heads then (
      let length = ref (Array.length graph.heads) in
      while height >= !length do
        length := !length * 2
      done;
      let heads = Array.make !length None in
      let tails = Array.make !length None in
      Array.blit graph.heads 0 heads 0 (Array.length graph.heads);
      Array.blit graph.tails 0 tails 0 (Array.length graph.tails);
      graph.heads <- heads;
      graph.tails <- tails)

  let add_parent child parent =
    let length = Array.length child.parents in
    let parents = Array.make (length + 1) parent in
    Array.blit child.parents 0 parents 0 length;
    child.parents <- parents

  let make_node graph ~height ~children ~compute ~cutoff ~value =
    ensure_height graph height;
    let node =
      {
        graph;
        height;
        children;
        parents = [||];
        compute;
        cutoff;
        value;
        prev = value;
        written_at = -1;
        necessary = false;
        queued_at = -1;
        queue_next = None;
        admitted = false;
      }
    in
    Array.iter (fun child -> add_parent child node) children;
    node

  let var graph value =
    let accepted = ref value in
    let watch =
      make_node graph ~height:0 ~children:[||]
        ~compute:(fun () -> !accepted)
        ~cutoff:(fun published candidate -> published == candidate)
        ~value
    in
    { accepted; watch }

  let watch var = var.watch

  let const graph value =
    make_node graph ~height:0 ~children:[||] ~compute:(fun () -> value)
      ~cutoff:(fun published candidate -> published == candidate) ~value

  let map ?(cutoff = ( == )) f child =
    make_node child.graph ~height:(child.height + 1) ~children:[| child |]
      ~compute:(fun () -> f child.value) ~cutoff ~value:(f child.value)

  let map2 ?(cutoff = ( == )) f left right =
    if left.graph != right.graph then invalid_arg "graph mismatch";
    make_node left.graph ~height:(max left.height right.height + 1)
      ~children:[| left; right |]
      ~compute:(fun () -> f left.value right.value) ~cutoff
      ~value:(f left.value right.value)

  let enqueue node =
    let graph = node.graph in
    if node.necessary && node.queued_at <> graph.pass then (
      node.queued_at <- graph.pass;
      node.queue_next <- None;
      match graph.tails.(node.height) with
      | None ->
          graph.heads.(node.height) <- Some node;
          graph.tails.(node.height) <- Some node;
          if node.height > graph.highest then graph.highest <- node.height
      | Some tail ->
          tail.queue_next <- Some node;
          graph.tails.(node.height) <- Some node;
          if node.height > graph.highest then graph.highest <- node.height)

  let retain_admission node =
    let graph = node.graph in
    if not node.admitted then (
      if graph.admitted_length = Array.length graph.admitted_sources then
        graph.admitted_sources <- grow graph.admitted_sources;
      node.admitted <- true;
      graph.admitted_sources.(graph.admitted_length) <- Obj.repr node;
      graph.admitted_length <- graph.admitted_length + 1)

  let set graph var value =
    if var.watch.graph != graph then invalid_arg "graph mismatch";
    graph.counts.admissions <- graph.counts.admissions + 1;
    if !(var.accepted) != value then (
      var.accepted := value;
      retain_admission var.watch;
      enqueue var.watch)

  let rec activate node =
    if not node.necessary then (
      node.necessary <- true;
      Array.iter activate node.children;
      if Array.length node.children = 0 then (
        retain_admission node;
        enqueue node))

  let demand node =
    activate node;
    node

  let release node =
    let rec deactivate node =
      if node.necessary then (
        node.necessary <- false;
        Array.iter
          (fun child ->
            if not (Array.exists (fun parent -> parent.necessary) child.parents)
            then deactivate child)
          node.children)
    in
    deactivate node

  let pop graph height =
    match graph.heads.(height) with
    | None -> None
    | Some node ->
        graph.heads.(height) <- node.queue_next;
        if graph.heads.(height) = None then graph.tails.(height) <- None;
        node.queue_next <- None;
        Some node

  let touch node =
    let graph = node.graph in
    if node.written_at <> graph.pass then (
      if graph.touched_length = Array.length graph.touched then
        graph.touched <- grow graph.touched;
      node.prev <- node.value;
      node.written_at <- graph.pass;
      graph.touched.(graph.touched_length) <- Obj.repr node;
      graph.touched_length <- graph.touched_length + 1;
      if graph.touched_length > graph.touched_high_water then
        graph.touched_high_water <- graph.touched_length)

  let rec recompute node =
    let graph = node.graph in
    graph.counts.claims <- graph.counts.claims + 1;
    let candidate = node.compute () in
    if node.height > 0 then (
      graph.counts.evaluations <- graph.counts.evaluations + 1;
      graph.counts.cutoffs <- graph.counts.cutoffs + 1;
      graph.counts.dependency_edges <-
        graph.counts.dependency_edges + Array.length node.children);
    if node.cutoff node.value candidate then false
    else (
      touch node;
      node.value <- candidate;
      Array.iter
        (fun parent ->
          graph.counts.propagation_edges <-
            graph.counts.propagation_edges + 1;
          if Array.length node.parents = 1
             && Array.length parent.children = 1
             && parent.height = node.height + 1
          then ignore (recompute parent)
          else enqueue parent)
        node.parents;
      true)

  let rollback graph =
    for index = graph.touched_length - 1 downto 0 do
      let node : node = Obj.obj graph.touched.(index) in
      node.value <- node.prev;
      node.written_at <- -1
    done;
    graph.touched_length <- 0

  let drain_frontier graph =
    for height = 0 to graph.highest do
      let rec loop () =
        match pop graph height with
        | None -> ()
        | Some node ->
            node.queued_at <- -1;
            loop ()
      in
      loop ()
    done;
    graph.highest <- -1

  let clear_admissions graph =
    for index = 0 to graph.admitted_length - 1 do
      let node : node = Obj.obj graph.admitted_sources.(index) in
      node.admitted <- false;
      graph.admitted_sources.(index) <- Obj.repr 0
    done;
    graph.admitted_length <- 0

  let replay_admissions graph =
    for index = 0 to graph.admitted_length - 1 do
      let node : node = Obj.obj graph.admitted_sources.(index) in
      enqueue node
    done

  let[@inline always] stabilize graph =
    if graph.running then Error Reentrant_stabilization
    else (
      graph.running <- true;
      let rec drain height changed =
        if height > graph.highest then changed
        else
          match pop graph height with
          | None -> drain (height + 1) changed
          | Some node -> drain height (recompute node || changed)
      in
      match drain 0 false with
      | changed ->
          graph.highest <- -1;
          graph.touched_length <- 0;
          clear_admissions graph;
          graph.pass <- graph.pass + 1;
          graph.running <- false;
          Ok (if changed then Committed else Quiescent)
      | exception exn ->
          rollback graph;
          drain_frontier graph;
          graph.pass <- graph.pass + 1;
          replay_admissions graph;
          graph.running <- false;
          Error (Defect exn))

  let value node = node.value
  let var_value var = !(var.accepted)
  let counts graph = graph.counts
  let touched_length graph = graph.touched_length
  let touched_high_water graph = graph.touched_high_water

  let touched_slot_is graph index node =
    index < Array.length graph.touched
    && Obj.repr node == graph.touched.(index)
end


module R1n = struct
  type nonrec stabilization = stabilization
  type nonrec error = error
  type nonrec counts = counts

  type node = {
    graph : graph;
    height : int;
    children : node array;
    mutable parents : node array;
    compute : unit -> int;
    cutoff : int -> int -> bool;
    mutable value : int;
    mutable prev : int;
    mutable written_at : int;
    mutable necessary : bool;
    mutable queued_at : int;
    mutable queue_next : node option;
    mutable admitted : bool;
  }

  and graph = {
    mutable pass : int;
    mutable running : bool;
    mutable highest : int;
    mutable heads : node option array;
    mutable tails : node option array;
    mutable touched : Obj.t array;
    mutable touched_length : int;
    mutable touched_high_water : int;
    mutable admitted_sources : Obj.t array;
    mutable admitted_length : int;
    counts : counts;
  }

  type signal = node
  type var = { accepted : int ref; watch : node }
  type demand = node

  let create () =
    {
      pass = 0;
      running = false;
      highest = -1;
      heads = Array.make 4 None;
      tails = Array.make 4 None;
      touched = Array.make 16 (Obj.repr 0);
      touched_length = 0;
      touched_high_water = 0;
      admitted_sources = Array.make 4 (Obj.repr 0);
      admitted_length = 0;
      counts =
        {
          admissions = 0;
          claims = 0;
          dependency_edges = 0;
          propagation_edges = 0;
          evaluations = 0;
          cutoffs = 0;
        };
    }

  let reset_counts graph =
    graph.counts.admissions <- 0;
    graph.counts.claims <- 0;
    graph.counts.dependency_edges <- 0;
    graph.counts.propagation_edges <- 0;
    graph.counts.evaluations <- 0;
    graph.counts.cutoffs <- 0

  let grow buffer =
    let next = Array.make (Array.length buffer * 2) (Obj.repr 0) in
    Array.blit buffer 0 next 0 (Array.length buffer);
    next

  let ensure_height graph height =
    if height >= Array.length graph.heads then (
      let length = ref (Array.length graph.heads) in
      while height >= !length do
        length := !length * 2
      done;
      let heads = Array.make !length None in
      let tails = Array.make !length None in
      Array.blit graph.heads 0 heads 0 (Array.length graph.heads);
      Array.blit graph.tails 0 tails 0 (Array.length graph.tails);
      graph.heads <- heads;
      graph.tails <- tails)

  let add_parent child parent =
    let length = Array.length child.parents in
    let parents = Array.make (length + 1) parent in
    Array.blit child.parents 0 parents 0 length;
    child.parents <- parents

  let make_node graph ~height ~children ~compute ~cutoff ~value =
    ensure_height graph height;
    let node =
      {
        graph;
        height;
        children;
        parents = [||];
        compute;
        cutoff;
        value;
        prev = value;
        written_at = -1;
        necessary = false;
        queued_at = -1;
        queue_next = None;
        admitted = false;
      }
    in
    Array.iter (fun child -> add_parent child node) children;
    node

  let var graph value =
    let accepted = ref value in
    let watch =
      make_node graph ~height:0 ~children:[||]
        ~compute:(fun () -> !accepted)
        ~cutoff:(fun published candidate -> published == candidate)
        ~value
    in
    { accepted; watch }

  let watch var = var.watch

  let const graph value =
    make_node graph ~height:0 ~children:[||] ~compute:(fun () -> value)
      ~cutoff:(fun published candidate -> published == candidate) ~value

  let map ?(cutoff = ( == )) f child =
    make_node child.graph ~height:(child.height + 1) ~children:[| child |]
      ~compute:(fun () -> f child.value) ~cutoff ~value:(f child.value)

  let map2 ?(cutoff = ( == )) f left right =
    if left.graph != right.graph then invalid_arg "graph mismatch";
    make_node left.graph ~height:(max left.height right.height + 1)
      ~children:[| left; right |]
      ~compute:(fun () -> f left.value right.value) ~cutoff
      ~value:(f left.value right.value)

  let enqueue node =
    let graph = node.graph in
    if node.necessary && node.queued_at <> graph.pass then (
      node.queued_at <- graph.pass;
      node.queue_next <- None;
      match graph.tails.(node.height) with
      | None ->
          graph.heads.(node.height) <- Some node;
          graph.tails.(node.height) <- Some node;
          if node.height > graph.highest then graph.highest <- node.height
      | Some tail ->
          tail.queue_next <- Some node;
          graph.tails.(node.height) <- Some node;
          if node.height > graph.highest then graph.highest <- node.height)

  let retain_admission node =
    let graph = node.graph in
    if not node.admitted then (
      if graph.admitted_length = Array.length graph.admitted_sources then
        graph.admitted_sources <- grow graph.admitted_sources;
      node.admitted <- true;
      graph.admitted_sources.(graph.admitted_length) <- Obj.repr node;
      graph.admitted_length <- graph.admitted_length + 1)

  let set graph var value =
    if var.watch.graph != graph then invalid_arg "graph mismatch";
    graph.counts.admissions <- graph.counts.admissions + 1;
    if !(var.accepted) != value then (
      var.accepted := value;
      retain_admission var.watch;
      enqueue var.watch)

  let rec activate node =
    if not node.necessary then (
      node.necessary <- true;
      Array.iter activate node.children;
      if Array.length node.children = 0 then (
        retain_admission node;
        enqueue node))

  let demand node =
    activate node;
    node

  let release node =
    let rec deactivate node =
      if node.necessary then (
        node.necessary <- false;
        Array.iter
          (fun child ->
            if not (Array.exists (fun parent -> parent.necessary) child.parents)
            then deactivate child)
          node.children)
    in
    deactivate node

  let pop graph height =
    match graph.heads.(height) with
    | None -> None
    | Some node ->
        graph.heads.(height) <- node.queue_next;
        if graph.heads.(height) = None then graph.tails.(height) <- None;
        node.queue_next <- None;
        Some node

  let touch node =
    let graph = node.graph in
    if node.written_at <> graph.pass then (
      if graph.touched_length = Array.length graph.touched then
        graph.touched <- grow graph.touched;
      node.prev <- node.value;
      node.written_at <- graph.pass;
      graph.touched.(graph.touched_length) <- Obj.repr node;
      graph.touched_length <- graph.touched_length + 1;
      if graph.touched_length > graph.touched_high_water then
        graph.touched_high_water <- graph.touched_length)

  let rec recompute node =
    let graph = node.graph in
    graph.counts.claims <- graph.counts.claims + 1;
    let candidate = node.compute () in
    if node.height > 0 then (
      graph.counts.evaluations <- graph.counts.evaluations + 1;
      graph.counts.cutoffs <- graph.counts.cutoffs + 1;
      graph.counts.dependency_edges <-
        graph.counts.dependency_edges + Array.length node.children);
    if node.cutoff node.value candidate then false
    else (
      node.value <- candidate;
      for index = 0 to Array.length node.parents - 1 do
        let parent = node.parents.(index) in
        graph.counts.propagation_edges <-
          graph.counts.propagation_edges + 1;
        if Array.length node.parents = 1
           && Array.length parent.children = 1
           && parent.height = node.height + 1
        then ignore (recompute parent)
        else enqueue parent
      done;
      true)

  let rollback graph =
    for index = graph.touched_length - 1 downto 0 do
      let node : node = Obj.obj graph.touched.(index) in
      node.value <- node.prev;
      node.written_at <- -1
    done;
    graph.touched_length <- 0

  let drain_frontier graph =
    for height = 0 to graph.highest do
      let rec loop () =
        match pop graph height with
        | None -> ()
        | Some node ->
            node.queued_at <- -1;
            loop ()
      in
      loop ()
    done;
    graph.highest <- -1

  let clear_admissions graph =
    for index = 0 to graph.admitted_length - 1 do
      let node : node = Obj.obj graph.admitted_sources.(index) in
      node.admitted <- false;
      graph.admitted_sources.(index) <- Obj.repr 0
    done;
    graph.admitted_length <- 0

  let replay_admissions graph =
    for index = 0 to graph.admitted_length - 1 do
      let node : node = Obj.obj graph.admitted_sources.(index) in
      enqueue node
    done

  let[@inline always] stabilize graph =
    if graph.running then Error Reentrant_stabilization
    else (
      graph.running <- true;
      let rec drain height changed =
        if height > graph.highest then changed
        else
          match pop graph height with
          | None -> drain (height + 1) changed
          | Some node -> drain height (recompute node || changed)
      in
      match drain 0 false with
      | changed ->
          graph.highest <- -1;
          graph.touched_length <- 0;
          clear_admissions graph;
          graph.pass <- graph.pass + 1;
          graph.running <- false;
          Ok (if changed then Committed else Quiescent)
      | exception exn ->
          graph.touched_length <- 0;
          drain_frontier graph;
          graph.pass <- graph.pass + 1;
          replay_admissions graph;
          graph.running <- false;
          Error (Defect exn))

  let value node = node.value
  let var_value var = !(var.accepted)
  let counts graph = graph.counts
  let touched_length graph = graph.touched_length
  let touched_high_water graph = graph.touched_high_water

  let touched_slot_is graph index node =
    index < Array.length graph.touched
    && Obj.repr node == graph.touched.(index)
end


module R1i = struct
  type nonrec stabilization = stabilization
  type nonrec error = error
  type nonrec counts = counts

  type node = {
    graph : graph;
    height : int;
    children : node array;
    mutable parents : node array;
    compute : unit -> int;
    cutoff : int -> int -> bool;
    mutable value : int;
    index : int;
    mutable prev : int;
    mutable written_at : int;
    mutable necessary : bool;
    mutable queued_at : int;
    mutable queue_next : node option;
    mutable admitted : bool;
  }

  and graph = {
    mutable pass : int;
    mutable running : bool;
    mutable highest : int;
    mutable heads : node option array;
    mutable tails : node option array;
    mutable nodes : node array;
    mutable node_count : int;
    mutable touched : int array;
    mutable touched_length : int;
    mutable touched_high_water : int;
    mutable admitted_sources : int array;
    mutable admitted_length : int;
    counts : counts;
  }

  type signal = node
  type var = { accepted : int ref; watch : node }
  type demand = node

  let create () =
    {
      pass = 0;
      running = false;
      highest = -1;
      heads = Array.make 4 None;
      tails = Array.make 4 None;
      nodes = [||];
      node_count = 0;
      touched = Array.make 16 0;
      touched_length = 0;
      touched_high_water = 0;
      admitted_sources = Array.make 4 0;
      admitted_length = 0;
      counts =
        {
          admissions = 0;
          claims = 0;
          dependency_edges = 0;
          propagation_edges = 0;
          evaluations = 0;
          cutoffs = 0;
        };
    }

  let reset_counts graph =
    graph.counts.admissions <- 0;
    graph.counts.claims <- 0;
    graph.counts.dependency_edges <- 0;
    graph.counts.propagation_edges <- 0;
    graph.counts.evaluations <- 0;
    graph.counts.cutoffs <- 0

  let grow buffer =
    let next = Array.make (Array.length buffer * 2) 0 in
    Array.blit buffer 0 next 0 (Array.length buffer);
    next

  let ensure_height graph height =
    if height >= Array.length graph.heads then (
      let length = ref (Array.length graph.heads) in
      while height >= !length do
        length := !length * 2
      done;
      let heads = Array.make !length None in
      let tails = Array.make !length None in
      Array.blit graph.heads 0 heads 0 (Array.length graph.heads);
      Array.blit graph.tails 0 tails 0 (Array.length graph.tails);
      graph.heads <- heads;
      graph.tails <- tails)

  let add_parent child parent =
    let length = Array.length child.parents in
    let parents = Array.make (length + 1) parent in
    Array.blit child.parents 0 parents 0 length;
    child.parents <- parents

  let make_node graph ~height ~children ~compute ~cutoff ~value =
    ensure_height graph height;
    let index = graph.node_count in
    let node =
      {
        graph;
        height;
        children;
        parents = [||];
        compute;
        cutoff;
        value;
        index;
        prev = value;
        written_at = -1;
        necessary = false;
        queued_at = -1;
        queue_next = None;
        admitted = false;
      }
    in
    if index = Array.length graph.nodes then
      graph.nodes <-
        if index = 0 then [| node |]
        else (
          let nodes = Array.make (index * 2) node in
          Array.blit graph.nodes 0 nodes 0 index;
          nodes);
    graph.nodes.(index) <- node;
    graph.node_count <- index + 1;
    Array.iter (fun child -> add_parent child node) children;
    node

  let var graph value =
    let accepted = ref value in
    let watch =
      make_node graph ~height:0 ~children:[||]
        ~compute:(fun () -> !accepted)
        ~cutoff:(fun published candidate -> published == candidate)
        ~value
    in
    { accepted; watch }

  let watch var = var.watch

  let const graph value =
    make_node graph ~height:0 ~children:[||] ~compute:(fun () -> value)
      ~cutoff:(fun published candidate -> published == candidate) ~value

  let map ?(cutoff = ( == )) f child =
    make_node child.graph ~height:(child.height + 1) ~children:[| child |]
      ~compute:(fun () -> f child.value) ~cutoff ~value:(f child.value)

  let map2 ?(cutoff = ( == )) f left right =
    if left.graph != right.graph then invalid_arg "graph mismatch";
    make_node left.graph ~height:(max left.height right.height + 1)
      ~children:[| left; right |]
      ~compute:(fun () -> f left.value right.value) ~cutoff
      ~value:(f left.value right.value)

  let enqueue node =
    let graph = node.graph in
    if node.necessary && node.queued_at <> graph.pass then (
      node.queued_at <- graph.pass;
      node.queue_next <- None;
      match graph.tails.(node.height) with
      | None ->
          graph.heads.(node.height) <- Some node;
          graph.tails.(node.height) <- Some node;
          if node.height > graph.highest then graph.highest <- node.height
      | Some tail ->
          tail.queue_next <- Some node;
          graph.tails.(node.height) <- Some node;
          if node.height > graph.highest then graph.highest <- node.height)

  let retain_admission node =
    let graph = node.graph in
    if not node.admitted then (
      if graph.admitted_length = Array.length graph.admitted_sources then
        graph.admitted_sources <- grow graph.admitted_sources;
      node.admitted <- true;
      graph.admitted_sources.(graph.admitted_length) <- node.index;
      graph.admitted_length <- graph.admitted_length + 1)

  let set graph var value =
    if var.watch.graph != graph then invalid_arg "graph mismatch";
    graph.counts.admissions <- graph.counts.admissions + 1;
    if !(var.accepted) != value then (
      var.accepted := value;
      retain_admission var.watch;
      enqueue var.watch)

  let rec activate node =
    if not node.necessary then (
      node.necessary <- true;
      Array.iter activate node.children;
      if Array.length node.children = 0 then (
        retain_admission node;
        enqueue node))

  let demand node =
    activate node;
    node

  let release node =
    let rec deactivate node =
      if node.necessary then (
        node.necessary <- false;
        Array.iter
          (fun child ->
            if not (Array.exists (fun parent -> parent.necessary) child.parents)
            then deactivate child)
          node.children)
    in
    deactivate node

  let pop graph height =
    match graph.heads.(height) with
    | None -> None
    | Some node ->
        graph.heads.(height) <- node.queue_next;
        if graph.heads.(height) = None then graph.tails.(height) <- None;
        node.queue_next <- None;
        Some node

  let touch node =
    let graph = node.graph in
    if node.written_at <> graph.pass then (
      if graph.touched_length = Array.length graph.touched then
        graph.touched <- grow graph.touched;
      node.prev <- node.value;
      node.written_at <- graph.pass;
      graph.touched.(graph.touched_length) <- node.index;
      graph.touched_length <- graph.touched_length + 1;
      if graph.touched_length > graph.touched_high_water then
        graph.touched_high_water <- graph.touched_length)

  let rec recompute node =
    let graph = node.graph in
    graph.counts.claims <- graph.counts.claims + 1;
    let candidate = node.compute () in
    if node.height > 0 then (
      graph.counts.evaluations <- graph.counts.evaluations + 1;
      graph.counts.cutoffs <- graph.counts.cutoffs + 1;
      graph.counts.dependency_edges <-
        graph.counts.dependency_edges + Array.length node.children);
    if node.cutoff node.value candidate then false
    else (
      touch node;
      node.value <- candidate;
      for index = 0 to Array.length node.parents - 1 do
        let parent = node.parents.(index) in
        graph.counts.propagation_edges <-
          graph.counts.propagation_edges + 1;
        if Array.length node.parents = 1
           && Array.length parent.children = 1
           && parent.height = node.height + 1
        then ignore (recompute parent)
        else enqueue parent
      done;
      true)

  let rollback graph =
    for index = graph.touched_length - 1 downto 0 do
      let node = graph.nodes.(graph.touched.(index)) in
      node.value <- node.prev;
      node.written_at <- -1
    done;
    graph.touched_length <- 0

  let drain_frontier graph =
    for height = 0 to graph.highest do
      let rec loop () =
        match pop graph height with
        | None -> ()
        | Some node ->
            node.queued_at <- -1;
            loop ()
      in
      loop ()
    done;
    graph.highest <- -1

  let clear_admissions graph =
    for index = 0 to graph.admitted_length - 1 do
      let node = graph.nodes.(graph.admitted_sources.(index)) in
      node.admitted <- false;
      graph.admitted_sources.(index) <- 0
    done;
    graph.admitted_length <- 0

  let replay_admissions graph =
    for index = 0 to graph.admitted_length - 1 do
      let node = graph.nodes.(graph.admitted_sources.(index)) in
      enqueue node
    done

  let[@inline always] stabilize graph =
    if graph.running then Error Reentrant_stabilization
    else (
      graph.running <- true;
      let rec drain height changed =
        if height > graph.highest then changed
        else
          match pop graph height with
          | None -> drain (height + 1) changed
          | Some node -> drain height (recompute node || changed)
      in
      match drain 0 false with
      | changed ->
          graph.highest <- -1;
          graph.touched_length <- 0;
          clear_admissions graph;
          graph.pass <- graph.pass + 1;
          graph.running <- false;
          Ok (if changed then Committed else Quiescent)
      | exception exn ->
          rollback graph;
          drain_frontier graph;
          graph.pass <- graph.pass + 1;
          replay_admissions graph;
          graph.running <- false;
          Error (Defect exn))

  let value node = node.value
  let var_value var = !(var.accepted)
  let counts graph = graph.counts
  let touched_length graph = graph.touched_length
  let touched_high_water graph = graph.touched_high_water

  let touched_slot_is graph index node =
    index < Array.length graph.touched
    && node.index = graph.touched.(index)
end


module R06 = struct
  type stabilization = Quiescent | Committed

  type counts = {
    mutable admissions : int;
    mutable claims : int;
    mutable dependency_edges : int;
    mutable propagation_edges : int;
    mutable evaluations : int;
    mutable cutoffs : int;
  }

  type node = {
    graph : graph;
    height : int;
    children : node array;
    mutable parents : node array;
    compute : unit -> int;
    cutoff : int -> int -> bool;
    mutable value : int;
    mutable necessary : bool;
    mutable queued_at : int;
    mutable queue_next : node option;
  }

  and graph = {
    mutable pass : int;
    mutable highest : int;
    mutable heads : node option array;
    mutable tails : node option array;
    counts : counts;
  }

  type signal = node

  type var = {
    accepted : int ref;
    watch : node;
  }

  type demand = node

  let create () =
    {
      pass = 0;
      highest = -1;
      heads = Array.make 4 None;
      tails = Array.make 4 None;
      counts =
        {
          admissions = 0;
          claims = 0;
          dependency_edges = 0;
          propagation_edges = 0;
          evaluations = 0;
          cutoffs = 0;
        };
    }

  let reset_counts t =
    t.counts.admissions <- 0;
    t.counts.claims <- 0;
    t.counts.dependency_edges <- 0;
    t.counts.propagation_edges <- 0;
    t.counts.evaluations <- 0;
    t.counts.cutoffs <- 0

  let ensure_height graph height =
    if height >= Array.length graph.heads then (
      let length = ref (Array.length graph.heads) in
      while height >= !length do
        length := !length * 2
      done;
      let heads = Array.make !length None in
      let tails = Array.make !length None in
      Array.blit graph.heads 0 heads 0 (Array.length graph.heads);
      Array.blit graph.tails 0 tails 0 (Array.length graph.tails);
      graph.heads <- heads;
      graph.tails <- tails)

  let add_parent child parent =
    let length = Array.length child.parents in
    let parents = Array.make (length + 1) parent in
    Array.blit child.parents 0 parents 0 length;
    child.parents <- parents

  let make_node graph ~height ~children ~compute ~cutoff ~value =
    ensure_height graph height;
    let node =
      {
        graph;
        height;
        children;
        parents = [||];
        compute;
        cutoff;
        value;
        necessary = false;
        queued_at = -1;
        queue_next = None;
      }
    in
    Array.iter (fun child -> add_parent child node) children;
    node

  let var graph value =
    let accepted = ref value in
    let watch =
      make_node graph ~height:0 ~children:[||]
        ~compute:(fun () -> !accepted)
        ~cutoff:(fun published candidate ->
          published == candidate)
        ~value
    in
    { accepted; watch }

  let watch var = var.watch

  let const graph value =
    make_node graph ~height:0 ~children:[||]
      ~compute:(fun () -> value)
      ~cutoff:(fun published candidate -> published == candidate)
      ~value

  let map ?(cutoff = ( == )) f child =
    let graph = child.graph in
    let initial = f child.value in
    make_node graph ~height:(child.height + 1) ~children:[| child |]
      ~compute:(fun () -> f child.value)
      ~cutoff ~value:initial

  let map2 ?(cutoff = ( == )) f left right =
    if left.graph != right.graph then invalid_arg "graph mismatch";
    let graph = left.graph in
    let height = max left.height right.height + 1 in
    let initial = f left.value right.value in
    make_node graph ~height ~children:[| left; right |]
      ~compute:(fun () -> f left.value right.value)
      ~cutoff ~value:initial

  let enqueue node =
    let graph = node.graph in
    if node.necessary && node.queued_at <> graph.pass then (
      node.queued_at <- graph.pass;
      node.queue_next <- None;
      let height = node.height in
      match graph.tails.(height) with
      | None ->
          graph.heads.(height) <- Some node;
          graph.tails.(height) <- Some node;
          if height > graph.highest then graph.highest <- height
      | Some tail ->
          tail.queue_next <- Some node;
          graph.tails.(height) <- Some node;
          if height > graph.highest then graph.highest <- height)

  let set graph var value =
    if var.watch.graph != graph then invalid_arg "graph mismatch";
    let graph = var.watch.graph in
    graph.counts.admissions <- graph.counts.admissions + 1;
    if !(var.accepted) != value then (
      var.accepted := value;
      enqueue var.watch)

  let rec activate node =
    if not node.necessary then (
      node.necessary <- true;
      Array.iter activate node.children;
      if Array.length node.children = 0 then enqueue node)

  let demand node =
    activate node;
    node

  let release node =
    let rec deactivate node =
      if node.necessary then (
        node.necessary <- false;
        Array.iter
          (fun child ->
            let retained =
              Array.exists
                (fun parent -> parent.necessary)
                child.parents
            in
            if not retained then deactivate child)
          node.children)
    in
    deactivate node

  let pop graph height =
    match graph.heads.(height) with
    | None -> None
    | Some node ->
        graph.heads.(height) <- node.queue_next;
        if graph.heads.(height) = None then graph.tails.(height) <- None;
        node.queue_next <- None;
        Some node

  let rec recompute node =
    let graph = node.graph in
    graph.counts.claims <- graph.counts.claims + 1;
    let candidate = node.compute () in
    if node.height > 0 then (
      graph.counts.evaluations <- graph.counts.evaluations + 1;
      graph.counts.cutoffs <- graph.counts.cutoffs + 1;
      graph.counts.dependency_edges <-
        graph.counts.dependency_edges + Array.length node.children);
    if node.cutoff node.value candidate then false
    else (
      node.value <- candidate;
      for index = 0 to Array.length node.parents - 1 do
        let parent = node.parents.(index) in
        graph.counts.propagation_edges <-
          graph.counts.propagation_edges + 1;
        if Array.length node.parents = 1
           && Array.length parent.children = 1
           && parent.height = node.height + 1
        then
          ignore (recompute parent)
        else enqueue parent
      done;
      true)

  type error = Static_kernel_error

  let stabilize graph =
    let rec drain height changed =
      if height > graph.highest then changed
      else
        match pop graph height with
        | None -> drain (height + 1) changed
        | Some node -> drain height (recompute node || changed)
    in
    let changed = drain 0 false in
    graph.highest <- -1;
    graph.pass <- graph.pass + 1;
    Ok (if changed then Committed else Quiescent)

  let value node = node.value
  let var_value var = !(var.accepted)
  let counts graph = graph.counts
end


module R2m = struct
  type nonrec stabilization = stabilization
  type nonrec error = error
  type nonrec counts = counts

  type node = {
    graph : graph;
    height : int;
    children : node array;
    mutable parents : node array;
    compute : unit -> int;
    cutoff : int -> int -> bool;
    mutable value : int;
    mutable candidate : int;
    mutable candidate_pass : int;
    mutable necessary : bool;
    mutable queued_at : int;
    mutable queue_next : node option;
    mutable admitted : bool;
  }

  and graph = {
    mutable pass : int;
    mutable running : bool;
    mutable highest : int;
    mutable heads : node option array;
    mutable tails : node option array;
    mutable touched : Obj.t array;
    mutable touched_length : int;
    mutable admitted_sources : Obj.t array;
    mutable admitted_length : int;
    counts : counts;
  }

  type signal = node
  type var = { accepted : int ref; watch : node }
  type demand = node

  let create () =
    {
      pass = 0;
      running = false;
      highest = -1;
      heads = Array.make 4 None;
      tails = Array.make 4 None;
      touched = Array.make 16 (Obj.repr 0);
      touched_length = 0;
      admitted_sources = Array.make 4 (Obj.repr 0);
      admitted_length = 0;
      counts =
        {
          admissions = 0;
          claims = 0;
          dependency_edges = 0;
          propagation_edges = 0;
          evaluations = 0;
          cutoffs = 0;
        };
    }

  let reset_counts graph =
    graph.counts.admissions <- 0;
    graph.counts.claims <- 0;
    graph.counts.dependency_edges <- 0;
    graph.counts.propagation_edges <- 0;
    graph.counts.evaluations <- 0;
    graph.counts.cutoffs <- 0

  let grow buffer =
    let next = Array.make (Array.length buffer * 2) (Obj.repr 0) in
    Array.blit buffer 0 next 0 (Array.length buffer);
    next

  let ensure_height graph height =
    if height >= Array.length graph.heads then (
      let length = ref (Array.length graph.heads) in
      while height >= !length do
        length := !length * 2
      done;
      let heads = Array.make !length None in
      let tails = Array.make !length None in
      Array.blit graph.heads 0 heads 0 (Array.length graph.heads);
      Array.blit graph.tails 0 tails 0 (Array.length graph.tails);
      graph.heads <- heads;
      graph.tails <- tails)

  let add_parent child parent =
    let length = Array.length child.parents in
    let parents = Array.make (length + 1) parent in
    Array.blit child.parents 0 parents 0 length;
    child.parents <- parents

  let read node =
    if node.candidate_pass = node.graph.pass then node.candidate else node.value

  let make_node graph ~height ~children ~compute ~cutoff ~value =
    ensure_height graph height;
    let node =
      {
        graph;
        height;
        children;
        parents = [||];
        compute;
        cutoff;
        value;
        candidate = value;
        candidate_pass = -1;
        necessary = false;
        queued_at = -1;
        queue_next = None;
        admitted = false;
      }
    in
    Array.iter (fun child -> add_parent child node) children;
    node

  let var graph value =
    let accepted = ref value in
    let watch =
      make_node graph ~height:0 ~children:[||]
        ~compute:(fun () -> !accepted)
        ~cutoff:(fun published candidate -> published == candidate)
        ~value
    in
    { accepted; watch }

  let watch var = var.watch

  let const graph value =
    make_node graph ~height:0 ~children:[||] ~compute:(fun () -> value)
      ~cutoff:(fun published candidate -> published == candidate) ~value

  let map ?(cutoff = ( == )) f child =
    make_node child.graph ~height:(child.height + 1) ~children:[| child |]
      ~compute:(fun () -> f (read child)) ~cutoff ~value:(f child.value)

  let map2 ?(cutoff = ( == )) f left right =
    if left.graph != right.graph then invalid_arg "graph mismatch";
    make_node left.graph ~height:(max left.height right.height + 1)
      ~children:[| left; right |]
      ~compute:(fun () -> f (read left) (read right)) ~cutoff
      ~value:(f left.value right.value)

  let enqueue node =
    let graph = node.graph in
    if node.necessary && node.queued_at <> graph.pass then (
      node.queued_at <- graph.pass;
      node.queue_next <- None;
      match graph.tails.(node.height) with
      | None ->
          graph.heads.(node.height) <- Some node;
          graph.tails.(node.height) <- Some node;
          if node.height > graph.highest then graph.highest <- node.height
      | Some tail ->
          tail.queue_next <- Some node;
          graph.tails.(node.height) <- Some node;
          if node.height > graph.highest then graph.highest <- node.height)

  let retain_admission node =
    let graph = node.graph in
    if not node.admitted then (
      if graph.admitted_length = Array.length graph.admitted_sources then
        graph.admitted_sources <- grow graph.admitted_sources;
      node.admitted <- true;
      graph.admitted_sources.(graph.admitted_length) <- Obj.repr node;
      graph.admitted_length <- graph.admitted_length + 1)

  let set graph var value =
    if var.watch.graph != graph then invalid_arg "graph mismatch";
    graph.counts.admissions <- graph.counts.admissions + 1;
    if !(var.accepted) != value then (
      var.accepted := value;
      retain_admission var.watch;
      enqueue var.watch)

  let rec activate node =
    if not node.necessary then (
      node.necessary <- true;
      Array.iter activate node.children;
      if Array.length node.children = 0 then (
        retain_admission node;
        enqueue node))

  let demand node =
    activate node;
    node

  let release node =
    let rec deactivate node =
      if node.necessary then (
        node.necessary <- false;
        Array.iter
          (fun child ->
            if not (Array.exists (fun parent -> parent.necessary) child.parents)
            then deactivate child)
          node.children)
    in
    deactivate node

  let pop graph height =
    match graph.heads.(height) with
    | None -> None
    | Some node ->
        graph.heads.(height) <- node.queue_next;
        if graph.heads.(height) = None then graph.tails.(height) <- None;
        node.queue_next <- None;
        Some node

  let touch node =
    let graph = node.graph in
    if node.candidate_pass <> graph.pass then (
      if graph.touched_length = Array.length graph.touched then
        graph.touched <- grow graph.touched;
      node.candidate_pass <- graph.pass;
      graph.touched.(graph.touched_length) <- Obj.repr node;
      graph.touched_length <- graph.touched_length + 1)

  let rec recompute node =
    let graph = node.graph in
    graph.counts.claims <- graph.counts.claims + 1;
    let candidate = node.compute () in
    if node.height > 0 then (
      graph.counts.evaluations <- graph.counts.evaluations + 1;
      graph.counts.cutoffs <- graph.counts.cutoffs + 1;
      graph.counts.dependency_edges <-
        graph.counts.dependency_edges + Array.length node.children);
    if node.cutoff node.value candidate then false
    else (
      touch node;
      node.candidate <- candidate;
      Array.iter
        (fun parent ->
          graph.counts.propagation_edges <-
            graph.counts.propagation_edges + 1;
          if Array.length node.parents = 1
             && Array.length parent.children = 1
             && parent.height = node.height + 1
          then ignore (recompute parent)
          else enqueue parent)
        node.parents;
      true)

  let publish graph =
    for index = 0 to graph.touched_length - 1 do
      let node : node = Obj.obj graph.touched.(index) in
      node.value <- node.candidate;
      node.candidate_pass <- -1
    done;
    graph.touched_length <- 0

  let drain_frontier graph =
    for height = 0 to graph.highest do
      let rec loop () =
        match pop graph height with
        | None -> ()
        | Some node ->
            node.queued_at <- -1;
            loop ()
      in
      loop ()
    done;
    graph.highest <- -1

  let clear_admissions graph =
    for index = 0 to graph.admitted_length - 1 do
      let node : node = Obj.obj graph.admitted_sources.(index) in
      node.admitted <- false;
      graph.admitted_sources.(index) <- Obj.repr 0
    done;
    graph.admitted_length <- 0

  let replay_admissions graph =
    for index = 0 to graph.admitted_length - 1 do
      let node : node = Obj.obj graph.admitted_sources.(index) in
      enqueue node
    done

  let[@inline always] stabilize graph =
    if graph.running then Error Reentrant_stabilization
    else (
      graph.running <- true;
      let rec drain height changed =
        if height > graph.highest then changed
        else
          match pop graph height with
          | None -> drain (height + 1) changed
          | Some node -> drain height (recompute node || changed)
      in
      match drain 0 false with
      | changed ->
          graph.highest <- -1;
          publish graph;
          clear_admissions graph;
          graph.pass <- graph.pass + 1;
          graph.running <- false;
          Ok (if changed then Committed else Quiescent)
      | exception exn ->
          graph.touched_length <- 0;
          drain_frontier graph;
          graph.pass <- graph.pass + 1;
          replay_admissions graph;
          graph.running <- false;
          Error (Defect exn))

  let value node = node.value
  let var_value var = !(var.accepted)
  let counts graph = graph.counts
end

module type KERNEL = sig
  type graph
  type signal
  type var
  type demand

  val create : unit -> graph
  val reset_counts : graph -> unit
  val var : graph -> int -> var
  val watch : var -> signal
  val const : graph -> int -> signal
  val map : ?cutoff:(int -> int -> bool) -> (int -> int) -> signal -> signal
  val map2 :
    ?cutoff:(int -> int -> bool) ->
    (int -> int -> int) ->
    signal ->
    signal ->
    signal
  val set : graph -> var -> int -> unit
  val demand : signal -> demand
  val release : demand -> unit
  val stabilize : graph -> (stabilization, error) result
  val value : signal -> int
  val var_value : var -> int
  val counts : graph -> counts
end

let failf format = Printf.ksprintf failwith format

let assert_int label expected actual =
  if actual <> expected then
    failf "%s: expected %d, observed %d" label expected actual

let expect_defect label = function
  | Error (Defect _) -> ()
  | Error Reentrant_stabilization ->
      failf "%s: observed reentrant error instead of defect" label
  | Ok Quiescent -> failf "%s: observed quiescent instead of defect" label
  | Ok Committed -> failf "%s: observed commit instead of defect" label

let expect_success label = function
  | Ok result -> result
  | Error Reentrant_stabilization -> failf "%s: reentrant error" label
  | Error (Defect exn) ->
      failf "%s: defect %s" label (Printexc.to_string exn)

module Checks (K : KERNEL) = struct
  let chain depth =
    let graph = K.create () in
    let source = K.var graph 0 in
    let rec loop remaining signal =
      if remaining = 0 then signal
      else loop (remaining - 1) (K.map (( + ) 1) signal)
    in
    let output = loop depth (K.watch source) in
    let _demand = K.demand output in
    graph, source, output

  let check_semantics name =
    let graph, source, output = chain 10 in
    K.reset_counts graph;
    K.set graph source 1;
    K.set graph source 2;
    assert_int (name ^ " accepted source value") 2 (K.var_value source);
    assert_int (name ^ " derived value before stabilization") 10
      (K.value output);
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " coalesced value") 12 (K.value output);
    let counts = K.counts graph in
    assert_int (name ^ " coalesced admissions") 2 counts.admissions;
    assert_int (name ^ " narrow claims") 11 counts.claims;
    assert_int (name ^ " narrow dependency edges") 10 counts.dependency_edges;
    assert_int (name ^ " narrow propagation edges") 10 counts.propagation_edges;
    assert_int (name ^ " narrow evaluations") 10 counts.evaluations;
    assert_int (name ^ " narrow cutoffs") 10 counts.cutoffs;

    K.reset_counts graph;
    K.set graph source 2;
    (match K.stabilize graph with
    | Ok Quiescent -> ()
    | Ok Committed -> failwith (name ^ " equal source admission committed")
    | Error _ -> failwith (name ^ " equal source admission failed"));
    assert_int (name ^ " quiescent admissions") 1 counts.admissions;
    assert_int (name ^ " quiescent claims") 0 counts.claims;
    assert_int (name ^ " quiescent dependency edges") 0 counts.dependency_edges;
    assert_int (name ^ " quiescent propagation edges") 0 counts.propagation_edges;
    assert_int (name ^ " quiescent evaluations") 0 counts.evaluations;
    assert_int (name ^ " quiescent cutoffs") 0 counts.cutoffs;

    let graph = K.create () in
    let source = K.var graph 0 in
    let constant = K.map ~cutoff:Int.equal (fun _ -> 0) (K.watch source) in
    let rec depend remaining signal =
      if remaining = 0 then signal
      else depend (remaining - 1) (K.map (( + ) 1) signal)
    in
    let output = depend 10 constant in
    let _demand = K.demand output in
    K.set graph source 1;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " cutoff propagation") 10 (K.value output);

    let graph = K.create () in
    let source = K.var graph 0 in
    let calls = ref [] in
    let output =
      K.map
        ~cutoff:(fun published candidate ->
          calls := (published, candidate) :: !calls;
          candidate = 1)
        Fun.id (K.watch source)
    in
    let _demand = K.demand output in
    K.set graph source 1;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " suppressed value") 0 (K.value output);
    K.set graph source 2;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " post-suppression value") 2 (K.value output);
    if List.rev !calls <> [ 0, 1; 0, 2 ] then
      failwith (name ^ " cutoff did not retain published baseline");

    let graph = K.create () in
    let source = K.var graph 1 in
    let order = ref 0 in
    let left =
      K.map
        (fun value ->
          order := (!order * 10) + 1;
          value + 1)
        (K.watch source)
    in
    let right =
      K.map
        (fun value ->
          order := (!order * 10) + 2;
          value + 2)
        (K.watch source)
    in
    let output =
      K.map2
        (fun left right ->
          order := (!order * 10) + 3;
          left + right)
        left right
    in
    let demand = K.demand output in
    order := 0;
    K.set graph source 2;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " fan-in value") 7 (K.value output);
    assert_int (name ^ " dependency order") 123 !order;
    K.release demand;
    order := 0;
    K.set graph source 3;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " released demand work") 0 !order;
    let _demand = K.demand output in
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " reactivated value") 9 (K.value output);

    let graph = K.create () in
    let left = K.var graph 0 in
    let right = K.var graph 0 in
    let output = K.map2 ( + ) (K.watch left) (K.watch right) in
    let _demand = K.demand output in
    ignore (expect_success name (K.stabilize graph));
    K.reset_counts graph;
    K.set graph left 1;
    ignore (expect_success name (K.stabilize graph));
    let counts = K.counts graph in
    assert_int (name ^ " fan-in dependency edges") 2 counts.dependency_edges;
    assert_int (name ^ " fan-in propagation edges") 1 counts.propagation_edges;

    let check_static_economics size =
      let graph = K.create () in
      let source = K.var graph 0 in
      let _ballast = Array.init (size - 1) (fun _ -> K.const graph 0) in
      let _demand = K.demand (K.watch source) in
      ignore (expect_success name (K.stabilize graph));
      K.reset_counts graph;
      K.set graph source 0;
      (match K.stabilize graph with
      | Ok Quiescent -> ()
      | Ok Committed -> failwith (name ^ " ballast graph committed")
      | Error _ -> failwith (name ^ " ballast graph failed"));
      let counts = K.counts graph in
      assert_int (name ^ " ballast quiescent admissions") 1 counts.admissions;
      assert_int (name ^ " ballast quiescent claims") 0 counts.claims;
      assert_int (name ^ " ballast quiescent dependency edges") 0
        counts.dependency_edges;
      assert_int (name ^ " ballast quiescent propagation edges") 0
        counts.propagation_edges;

      let graph, source, output = chain 10 in
      let _ballast = Array.init (size - 11) (fun _ -> K.const graph 0) in
      ignore (expect_success name (K.stabilize graph));
      K.reset_counts graph;
      K.set graph source 1;
      ignore (expect_success name (K.stabilize graph));
      let counts = K.counts graph in
      assert_int (name ^ " ballast narrow value") 11 (K.value output);
      assert_int (name ^ " ballast narrow claims") 11 counts.claims;
      assert_int (name ^ " ballast narrow dependency edges") 10
        counts.dependency_edges;
      assert_int (name ^ " ballast narrow propagation edges") 10
        counts.propagation_edges;
      assert_int (name ^ " ballast narrow evaluations") 10 counts.evaluations;
      assert_int (name ^ " ballast narrow cutoffs") 10 counts.cutoffs;

      let affected = (size - 1) / 2 in
      let graph, source, output = chain affected in
      let _ballast =
        Array.init (size - affected - 1) (fun _ -> K.const graph 0)
      in
      ignore (expect_success name (K.stabilize graph));
      K.reset_counts graph;
      K.set graph source 1;
      ignore (expect_success name (K.stabilize graph));
      let counts = K.counts graph in
      assert_int (name ^ " half-graph value") (affected + 1) (K.value output);
      assert_int (name ^ " half-graph claims") (affected + 1) counts.claims;
      assert_int (name ^ " half-graph dependency edges") affected
        counts.dependency_edges;
      assert_int (name ^ " half-graph propagation edges") affected
        counts.propagation_edges;
      assert_int (name ^ " half-graph evaluations") affected counts.evaluations;
      assert_int (name ^ " half-graph cutoffs") affected counts.cutoffs
    in
    List.iter check_static_economics [ 1_000; 10_000; 100_000 ];

    let check_reduction size =
      let graph = K.create () in
      let sources = Array.init size (fun _ -> K.var graph 0) in
      let level = ref (Array.map K.watch sources) in
      let combine_calls = ref 0 in
      while Array.length !level > 1 do
        let current = !level in
        level :=
          Array.init (Array.length current / 2) (fun index ->
              K.map2 ~cutoff:(fun _ _ -> false)
                (fun left right ->
                  incr combine_calls;
                  left + right)
                current.(index * 2) current.((index * 2) + 1))
      done;
      assert_int (name ^ " reduction construction calls") (size - 1)
        !combine_calls;
      let aggregate_cutoff_calls = ref 0 in
      let output =
        K.map
          ~cutoff:(fun _ candidate ->
            incr aggregate_cutoff_calls;
            candidate = 1)
          Fun.id (!level).(0)
      in
      let _demand = K.demand output in
      ignore (expect_success name (K.stabilize graph));
      K.reset_counts graph;
      combine_calls := 0;
      aggregate_cutoff_calls := 0;
      K.set graph sources.(0) 1;
      ignore (expect_success name (K.stabilize graph));
      let depth = int_of_float (Float.log2 (float_of_int size)) in
      let counts = K.counts graph in
      assert_int (name ^ " reduction suppressed value") 0 (K.value output);
      assert_int (name ^ " changed-leaf combination calls") depth !combine_calls;
      assert_int (name ^ " aggregate cutoff calls") 1 !aggregate_cutoff_calls;
      assert_int (name ^ " reduction claims") (depth + 2) counts.claims;
      assert_int (name ^ " reduction dependency edges") ((depth * 2) + 1)
        counts.dependency_edges;
      assert_int (name ^ " reduction propagation edges") (depth + 1)
        counts.propagation_edges;
      assert_int (name ^ " reduction evaluations") (depth + 1)
        counts.evaluations;
      assert_int (name ^ " reduction cutoff checks") (depth + 1) counts.cutoffs;
      combine_calls := 0;
      aggregate_cutoff_calls := 0;
      K.set graph sources.(0) 2;
      ignore (expect_success name (K.stabilize graph));
      assert_int (name ^ " reduction published value") 2 (K.value output);
      assert_int (name ^ " next combination calls") depth !combine_calls;
      assert_int (name ^ " next aggregate cutoff calls") 1
        !aggregate_cutoff_calls
    in
    let size = ref 1 in
    while !size <= 131_072 do
      check_reduction !size;
      size := !size * 2
    done

  let failing_chain depth failing_index =
    let graph = K.create () in
    let source = K.var graph 0 in
    let armed = ref false in
    let nodes = Array.make (depth + 1) (K.watch source) in
    for index = 1 to depth do
      nodes.(index) <-
        K.map
          (fun value ->
            if !armed && index = failing_index then raise Injected_failure;
            value + 1)
          nodes.(index - 1)
    done;
    let _demand = K.demand nodes.(depth) in
    graph, source, nodes, armed

  let check_failure_positions name =
    List.iter
      (fun depth ->
        let positions = List.sort_uniq Int.compare [ 1; max 1 (depth / 2); depth ] in
        List.iter
          (fun failing_index ->
            let graph, source, nodes, armed =
              failing_chain depth failing_index
            in
            let before = Array.map K.value nodes in
            K.set graph source 10;
            armed := true;
            expect_defect name (K.stabilize graph);
            Array.iteri
              (fun index expected ->
                assert_int
                  (Printf.sprintf "%s rollback depth %d failure %d node %d"
                     name depth failing_index index)
                  expected (K.value nodes.(index)))
              before)
          positions)
      [ 1; 10; 100 ]

  let check_retry_and_cutoff name =
    let graph, source, nodes, armed = failing_chain 10 6 in
    K.set graph source 2;
    armed := true;
    expect_defect name (K.stabilize graph);
    assert_int (name ^ " accepted value after failure") 2 (K.var_value source);
    armed := false;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " bare retry") 12 (K.value nodes.(10));

    let graph, source, nodes, armed = failing_chain 10 6 in
    K.set graph source 2;
    armed := true;
    expect_defect name (K.stabilize graph);
    K.set graph source 3;
    K.set graph source 4;
    armed := false;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " retry coalescing") 14 (K.value nodes.(10));

    let graph = K.create () in
    let source = K.var graph 0 in
    let calls = ref [] in
    let cutoff_node =
      K.map
        ~cutoff:(fun published candidate ->
          calls := (published, candidate) :: !calls;
          false)
        Fun.id (K.watch source)
    in
    let armed = ref false in
    let output =
      K.map
        (fun value ->
          if !armed then raise Injected_failure;
          value)
        cutoff_node
    in
    let _demand = K.demand output in
    K.set graph source 1;
    armed := true;
    expect_defect name (K.stabilize graph);
    K.set graph source 2;
    armed := false;
    ignore (expect_success name (K.stabilize graph));
    (match List.rev !calls with
    | [ (0, 1); (0, 2) ] -> ()
    | observed ->
        failf "%s cutoff after failure: expected [(0,1);(0,2)], observed length %d"
          name (List.length observed));
    assert_int (name ^ " cutoff retry value") 2 (K.value output)

  let check_repeated_failures name =
    let graph, source, nodes, armed = failing_chain 10 6 in
    K.set graph source 1;
    armed := true;
    for attempt = 1 to 3 do
      expect_defect (Printf.sprintf "%s failed attempt %d" name attempt)
        (K.stabilize graph);
      assert_int (name ^ " repeated rollback source") 0 (K.value nodes.(0));
      assert_int (name ^ " repeated rollback output") 10 (K.value nodes.(10))
    done;
    armed := false;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " repeated retry") 11 (K.value nodes.(10));
    K.set graph source 2;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " repeated residue") 12 (K.value nodes.(10))

  let check_diamond_frontier name =
    let graph = K.create () in
    let source = K.var graph 0 in
    let watched = K.watch source in
    let left_calls = ref 0 in
    let right_calls = ref 0 in
    let output_calls = ref 0 in
    let fail = ref false in
    let left =
      K.map
        (fun value ->
          incr left_calls;
          value + 1)
        watched
    in
    let right =
      K.map
        (fun value ->
          incr right_calls;
          if !fail then raise Injected_failure;
          value + 2)
        watched
    in
    let output =
      K.map2
        (fun left right ->
          incr output_calls;
          left + right)
        left right
    in
    let _demand = K.demand output in
    left_calls := 0;
    right_calls := 0;
    output_calls := 0;
    K.set graph source 1;
    fail := true;
    expect_defect name (K.stabilize graph);
    fail := false;
    K.reset_counts graph;
    left_calls := 0;
    right_calls := 0;
    output_calls := 0;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " retry left evaluations") 1 !left_calls;
    assert_int (name ^ " retry right evaluations") 1 !right_calls;
    assert_int (name ^ " retry output evaluations") 1 !output_calls;
    assert_int (name ^ " retry diamond value") 5 (K.value output);
    let counts = K.counts graph in
    assert_int (name ^ " retry diamond claims") 4 counts.claims;
    assert_int (name ^ " retry diamond dependency edges") 4
      counts.dependency_edges;
    assert_int (name ^ " retry diamond propagation edges") 4
      counts.propagation_edges;
    assert_int (name ^ " retry diamond evaluations") 3 counts.evaluations;
    assert_int (name ^ " retry diamond cutoffs") 3 counts.cutoffs

  let check_demand_failure name =
    let graph, source, nodes, armed = failing_chain 3 2 in
    let output = nodes.(3) in
    let demand = K.demand output in
    ignore (expect_success name (K.stabilize graph));
    K.release demand;
    K.set graph source 1;
    armed := true;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " released source remains old") 0 (K.value nodes.(0));
    assert_int (name ^ " released output remains old") 3 (K.value output);
    let _demand = K.demand output in
    expect_defect name (K.stabilize graph);
    assert_int (name ^ " reactivation rollback") 3 (K.value output);
    armed := false;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " reactivation fresh value") 4 (K.value output)

  let check_reentry name =
    let graph = K.create () in
    let source = K.var graph 0 in
    let saw_reentrant = ref false in
    let armed = ref false in
    let output =
      K.map
        (fun value ->
          if !armed then (
            (match K.stabilize graph with
            | Error Reentrant_stabilization -> saw_reentrant := true
            | _ -> failwith "nested stabilization did not return typed error");
            raise Injected_failure);
          value + 1)
        (K.watch source)
    in
    let _demand = K.demand output in
    K.set graph source 1;
    armed := true;
    expect_defect name (K.stabilize graph);
    if not !saw_reentrant then failwith (name ^ " did not observe reentry");
    assert_int (name ^ " reentry rollback") 1 (K.value output);
    armed := false;
    ignore (expect_success name (K.stabilize graph));
    assert_int (name ^ " reentry retry") 2 (K.value output)

  let check_quiescent_after_failure name =
    let graph, source, nodes, armed = failing_chain 3 2 in
    K.set graph source 1;
    armed := true;
    expect_defect name (K.stabilize graph);
    armed := false;
    ignore (expect_success name (K.stabilize graph));
    K.reset_counts graph;
    K.set graph source 1;
    (match K.stabilize graph with
    | Ok Quiescent -> ()
    | Ok Committed -> failwith (name ^ " same value committed after retry")
    | Error _ -> failwith (name ^ " same value failed after retry"));
    let counts = K.counts graph in
    assert_int (name ^ " post-failure quiescent claims") 0 counts.claims;
    assert_int (name ^ " post-failure quiescent dependency edges") 0
      counts.dependency_edges;
    assert_int (name ^ " post-failure quiescent propagation edges") 0
      counts.propagation_edges;
    assert_int (name ^ " post-failure quiescent evaluations") 0
      counts.evaluations;
    assert_int (name ^ " post-failure quiescent cutoffs") 0 counts.cutoffs;
    assert_int (name ^ " post-failure value") 4 (K.value nodes.(3))

  let run name =
    Printf.printf "%s inherited checks\n%!" name;
    check_semantics name;
    Printf.printf "%s failure-position checks\n%!" name;
    check_failure_positions name;
    Printf.printf "%s retry and cutoff checks\n%!" name;
    check_retry_and_cutoff name;
    Printf.printf "%s repeated-failure checks\n%!" name;
    check_repeated_failures name;
    Printf.printf "%s frontier checks\n%!" name;
    check_diamond_frontier name;
    Printf.printf "%s demand checks\n%!" name;
    check_demand_failure name;
    Printf.printf "%s reentry checks\n%!" name;
    check_reentry name;
    Printf.printf "%s quiescent checks\n%!" name;
    check_quiescent_after_failure name;
    Printf.printf "%s checks passed\n%!" name
end

module R1_checks = Checks (R1)
module R2_checks = Checks (R2)
module R1b_checks = Checks (R1b)
module R1m_checks = Checks (R1m)
module R2m_checks = Checks (R2m)
module R1w_checks = Checks (R1w)
module R1i_checks = Checks (R1i)

module Lazy_epoch = struct
  type node = {
    mutable value : int;
    mutable prev : int;
    mutable written_at : int;
  }

  type graph = {
    mutable pass : int;
    mutable committed : int;
    mutable accepted : int;
    gate : node;
    output : node;
  }

  let create () =
    {
      pass = 0;
      committed = 0;
      accepted = 0;
      gate = { value = 0; prev = 0; written_at = -1 };
      output = { value = 0; prev = 0; written_at = -1 };
    }

  let read graph node =
    if node.written_at > graph.committed then node.prev else node.value

  let write graph node candidate =
    if node.written_at <> graph.pass then node.prev <- read graph node;
    node.value <- candidate;
    node.written_at <- graph.pass

  let child_read graph node =
    if node.written_at = graph.pass then node.value else read graph node

  let failed_pass graph : (stabilization, error) result =
    graph.pass <- graph.pass + 1;
    write graph graph.gate graph.accepted;
    write graph graph.output (child_read graph graph.gate);
    Error (Defect Injected_failure)

  let successful_cutoff_pass graph :
      bool * (stabilization, error) result =
    graph.pass <- graph.pass + 1;
    let published_gate = read graph graph.gate in
    let candidate_gate = graph.accepted in
    let cutoff_suppressed = published_gate = 0 && candidate_gate = 2 in
    if not cutoff_suppressed then (
      write graph graph.gate candidate_gate;
      write graph graph.output (child_read graph graph.gate));
    graph.committed <- graph.pass;
    cutoff_suppressed, Ok Committed
end

let check_r3_counterexample () =
  let graph = Lazy_epoch.create () in
  graph.accepted <- 1;
  expect_defect "R3 failed pass" (Lazy_epoch.failed_pass graph);
  let after_failed_pass = Lazy_epoch.read graph graph.output in
  graph.accepted <- 2;
  let cutoff_suppressed_n, result =
    Lazy_epoch.successful_cutoff_pass graph
  in
  ignore (expect_success "R3 cutoff pass" result);
  let observed = Lazy_epoch.read graph graph.output in
  let expected = 0 in
  Printf.printf
    "R3 counterexample: failed_pass=1 failed_candidate=1 \
     next_pass=2 next_candidate=2 cutoff_suppressed_n=true \
     after_failure=%d committed=2 observed=%d expected=%d\n%!"
    after_failed_pass observed expected;
  if (not cutoff_suppressed_n)
     || after_failed_pass <> 0
     || observed <> 1
     || observed = expected
  then
    failwith "R3 counterexample did not falsify lazy epoch"

let check_slot_clearing_allocation () =
  let operations = 1_000_000 in
  let retained = ref 0 in
  let slots = [| Obj.repr retained |] in
  Gc.full_major ();
  let before_minor, before_promoted, before_major = Gc.counters () in
  for _ = 1 to operations do
    slots.(0) <- Obj.repr 0;
    slots.(0) <- Obj.repr retained
  done;
  let after_minor, after_promoted, after_major = Gc.counters () in
  let words =
    ((after_minor -. before_minor)
     +. (after_major -. before_major)
     -. (after_promoted -. before_promoted))
    /. float_of_int operations
  in
  Printf.printf "R1 touched-slot clearing allocation: %.6f words/slot\n%!" words;
  if words >= 0.001 then
    failf "R1 touched-slot clearing allocated %.6f words/slot" words

let check_r1b_retention_bound () =
  let graph = R1b.create () in
  let left = R1b.var graph 0 in
  let right = R1b.var graph 0 in
  let left_output = R1b.map (( + ) 1) (R1b.watch left) in
  let right_output = R1b.map (( + ) 1) (R1b.watch right) in
  let _left_demand = R1b.demand left_output in
  let _right_demand = R1b.demand right_output in
  ignore (expect_success "R1b initial pass" (R1b.stabilize graph));
  assert_int "R1b initial high-water mark" 0
    (R1b.touched_high_water graph);
  assert_int "R1b initial active length" 0 (R1b.touched_length graph);
  R1b.set graph left 1;
  ignore (expect_success "R1b left pass" (R1b.stabilize graph));
  assert_int "R1b left-pass high-water mark" 2
    (R1b.touched_high_water graph);
  if not (R1b.touched_slot_is graph 0 (R1b.watch left)) then
    failwith "R1b left pass did not leave its bounded stale slot";
  R1b.set graph right 1;
  ignore (expect_success "R1b right pass" (R1b.stabilize graph));
  if R1b.touched_slot_is graph 0 (R1b.watch left) then
    failwith "R1b later pass did not overwrite the stale slot";
  if not (R1b.touched_slot_is graph 0 (R1b.watch right)) then
    failwith "R1b later pass did not install the new stale slot";
  assert_int "R1b final active length" 0 (R1b.touched_length graph);
  assert_int "R1b bounded high-water mark" 2
    (R1b.touched_high_water graph)

type workload = {
  name : string;
  run_batch : int -> unit;
  check : unit -> unit;
}

module Workloads (K : KERNEL) = struct
  let chain depth =
    let graph = K.create () in
    let source = K.var graph 0 in
    let rec loop remaining signal =
      if remaining = 0 then signal
      else loop (remaining - 1) (K.map (( + ) 1) signal)
    in
    let output = loop depth (K.watch source) in
    let _demand = K.demand output in
    ignore (expect_success "workload warm-up" (K.stabilize graph));
    graph, source, output

  let changed prefix depth =
    let graph, source, output = chain depth in
    let next = ref 0 in
    let run_batch operations =
      for _ = 1 to operations do
        incr next;
        K.set graph source !next;
        ignore (K.stabilize graph)
      done
    in
    let check () =
      assert_int (prefix ^ " changed") (!next + depth) (K.value output)
    in
    {
      name = Printf.sprintf "%s.changed.depth_%d" prefix depth;
      run_batch;
      check;
    }

  let cutoff prefix depth =
    let graph = K.create () in
    let source = K.var graph 0 in
    let constant = K.map ~cutoff:Int.equal (fun _ -> 0) (K.watch source) in
    let rec loop remaining signal =
      if remaining = 0 then signal
      else loop (remaining - 1) (K.map (( + ) 1) signal)
    in
    let output = loop depth constant in
    let _demand = K.demand output in
    ignore (expect_success "workload warm-up" (K.stabilize graph));
    let next = ref 0 in
    let run_batch operations =
      for _ = 1 to operations do
        incr next;
        K.set graph source !next;
        ignore (K.stabilize graph)
      done
    in
    let check () = assert_int (prefix ^ " cutoff") depth (K.value output) in
    {
      name = Printf.sprintf "%s.cutoff.depth_%d" prefix depth;
      run_batch;
      check;
    }

  let fan_in prefix =
    let graph = K.create () in
    let source = K.var graph 0 in
    let watched = K.watch source in
    let left = K.map (( + ) 1) watched in
    let right = K.map (( + ) 2) watched in
    let output = K.map2 ( + ) left right in
    let _demand = K.demand output in
    ignore (expect_success "workload warm-up" (K.stabilize graph));
    let next = ref 0 in
    let run_batch operations =
      for _ = 1 to operations do
        incr next;
        K.set graph source !next;
        ignore (K.stabilize graph)
      done
    in
    let check () =
      assert_int (prefix ^ " fan-in") ((!next * 2) + 3) (K.value output)
    in
    { name = prefix ^ ".fan_in.diamond"; run_batch; check }

  let failed_retry prefix depth =
    let graph = K.create () in
    let source = K.var graph 0 in
    let armed = ref false in
    let rec loop remaining signal =
      if remaining = 0 then
        K.map
          (fun value ->
            if !armed then raise Injected_failure;
            value)
          signal
      else loop (remaining - 1) (K.map (( + ) 1) signal)
    in
    let output = loop depth (K.watch source) in
    let _demand = K.demand output in
    ignore (expect_success "workload warm-up" (K.stabilize graph));
    let next = ref 0 in
    let run_batch operations =
      for _ = 1 to operations do
        incr next;
        K.set graph source !next;
        armed := true;
        ignore (K.stabilize graph);
        armed := false;
        ignore (K.stabilize graph)
      done
    in
    let check () =
      assert_int (prefix ^ " failed retry") (!next + depth) (K.value output)
    in
    {
      name = Printf.sprintf "%s.failed_retry.depth_%d" prefix depth;
      run_batch;
      check;
    }
end

module R1_workloads = Workloads (R1)
module R2_workloads = Workloads (R2)
module R1b_workloads = Workloads (R1b)
module R1m_workloads = Workloads (R1m)
module R2m_workloads = Workloads (R2m)
module R1w_workloads = Workloads (R1w)
module R1n_workloads = Workloads (R1n)
module R1i_workloads = Workloads (R1i)
module R1a_workloads = Workloads (R1a)

let make_r06_changed depth =
  let graph = R06.create () in
  let source = R06.var graph 0 in
  let rec chain remaining signal =
    if remaining = 0 then signal
    else chain (remaining - 1) (R06.map (( + ) 1) signal)
  in
  let output = chain depth (R06.watch source) in
  let _demand = R06.demand output in
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      R06.set graph source !next;
      ignore (R06.stabilize graph)
    done
  in
  let check () =
    assert_int "r06 changed" (!next + depth) (R06.value output)
  in
  {
    name = Printf.sprintf "r06.changed.depth_%d" depth;
    run_batch;
    check;
  }

let make_r06_cutoff depth =
  let graph = R06.create () in
  let source = R06.var graph 0 in
  let constant =
    R06.map ~cutoff:Int.equal (fun _ -> 0) (R06.watch source)
  in
  let rec chain remaining signal =
    if remaining = 0 then signal
    else chain (remaining - 1) (R06.map (( + ) 1) signal)
  in
  let output = chain depth constant in
  let _demand = R06.demand output in
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      R06.set graph source !next;
      ignore (R06.stabilize graph)
    done
  in
  let check () = assert_int "r06 cutoff" depth (R06.value output) in
  {
    name = Printf.sprintf "r06.cutoff.depth_%d" depth;
    run_batch;
    check;
  }

let make_r1m_changed depth =
  let graph = R1m.create () in
  let source = R1m.var graph 0 in
  let rec chain remaining signal =
    if remaining = 0 then signal
    else chain (remaining - 1) (R1m.map (( + ) 1) signal)
  in
  let output = chain depth (R1m.watch source) in
  let _demand = R1m.demand output in
  ignore (R1m.stabilize graph);
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      R1m.set graph source !next;
      ignore (R1m.stabilize graph)
    done
  in
  let check () =
    assert_int "r1m changed" (!next + depth) (R1m.value output)
  in
  {
    name = Printf.sprintf "r1m.changed.depth_%d" depth;
    run_batch;
    check;
  }

let make_r2m_changed depth =
  let graph = R2m.create () in
  let source = R2m.var graph 0 in
  let rec chain remaining signal =
    if remaining = 0 then signal
    else chain (remaining - 1) (R2m.map (( + ) 1) signal)
  in
  let output = chain depth (R2m.watch source) in
  let _demand = R2m.demand output in
  ignore (R2m.stabilize graph);
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      R2m.set graph source !next;
      ignore (R2m.stabilize graph)
    done
  in
  let check () =
    assert_int "r2m changed" (!next + depth) (R2m.value output)
  in
  {
    name = Printf.sprintf "r2m.changed.depth_%d" depth;
    run_batch;
    check;
  }

let make_incremental_changed depth =
  let module Incr = Incremental.Make () in
  let source = Incr.Var.create 0 in
  let rec chain remaining signal =
    if remaining = 0 then signal
    else chain (remaining - 1) (Incr.map signal ~f:(( + ) 1))
  in
  let output = chain depth (Incr.Var.watch source) in
  let observer = Incr.observe output in
  Incr.stabilize ();
  let next = ref 0 in
  let observed = ref (Incr.Observer.value_exn observer) in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Incr.Var.set source !next;
      Incr.stabilize ()
    done
  in
  let check () =
    observed := Incr.Observer.value_exn observer;
    assert_int "Incremental changed" (!next + depth) !observed
  in
  {
    name = Printf.sprintf "incremental.raw.changed.depth_%d" depth;
    run_batch;
    check;
  }

let make_incremental_cutoff depth =
  let module Incr = Incremental.Make () in
  let source = Incr.Var.create 0 in
  let constant = Incr.map (Incr.Var.watch source) ~f:(fun _ -> 0) in
  let rec depend remaining signal =
    if remaining = 0 then signal
    else depend (remaining - 1) (Incr.map signal ~f:(( + ) 1))
  in
  let output = depend depth constant in
  let observer = Incr.observe output in
  Incr.stabilize ();
  let next = ref 0 in
  let observed = ref (Incr.Observer.value_exn observer) in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Incr.Var.set source !next;
      Incr.stabilize ()
    done
  in
  let check () =
    observed := Incr.Observer.value_exn observer;
    assert_int "Incremental cutoff" depth !observed
  in
  {
    name = Printf.sprintf "incremental.raw.cutoff.depth_%d" depth;
    run_batch;
    check;
  }

let elapsed f =
  let started = Unix.gettimeofday () in
  f ();
  Unix.gettimeofday () -. started

let rec calibrate workload operations =
  let seconds = elapsed (fun () -> workload.run_batch operations) in
  workload.check ();
  if seconds >= 0.5 || operations >= 16_777_216 then operations
  else calibrate workload (operations * 2)

let measure ~sample_count workload =
  let operations = calibrate workload 1 in
  workload.run_batch operations;
  workload.check ();
  Gc.full_major ();
  for sample = 1 to sample_count do
    let before_minor, before_promoted, before_major = Gc.counters () in
    let started = Unix.gettimeofday () in
    workload.run_batch operations;
    let stopped = Unix.gettimeofday () in
    let after_minor, after_promoted, after_major = Gc.counters () in
    workload.check ();
    let count = float_of_int operations in
    let wall_ns = ((stopped -. started) *. 1e9) /. count in
    let allocated_words =
      ((after_minor -. before_minor)
       +. (after_major -. before_major)
       -. (after_promoted -. before_promoted))
      /. count
    in
    Printf.printf "%s,%d,%d,%.6f,%.6f\n%!" workload.name operations sample
      wall_ns allocated_words
  done

let candidates =
  [
    "r1.changed.depth_1", (fun () -> R1_workloads.changed "r1" 1);
    "r1.changed.depth_10", (fun () -> R1_workloads.changed "r1" 10);
    "r1.changed.depth_100", (fun () -> R1_workloads.changed "r1" 100);
    "r1.cutoff.depth_10", (fun () -> R1_workloads.cutoff "r1" 10);
    "r1.fan_in.diamond", (fun () -> R1_workloads.fan_in "r1");
    "r2.changed.depth_1", (fun () -> R2_workloads.changed "r2" 1);
    "r2.changed.depth_10", (fun () -> R2_workloads.changed "r2" 10);
    "r2.changed.depth_100", (fun () -> R2_workloads.changed "r2" 100);
    "r2.cutoff.depth_10", (fun () -> R2_workloads.cutoff "r2" 10);
    "r2.fan_in.diamond", (fun () -> R2_workloads.fan_in "r2");
    "r1.failed_retry.depth_1",
      (fun () -> R1_workloads.failed_retry "r1" 1);
    "r1.failed_retry.depth_10",
      (fun () -> R1_workloads.failed_retry "r1" 10);
    "r1.failed_retry.depth_100",
      (fun () -> R1_workloads.failed_retry "r1" 100);
    "r2.failed_retry.depth_1",
      (fun () -> R2_workloads.failed_retry "r2" 1);
    "r2.failed_retry.depth_10",
      (fun () -> R2_workloads.failed_retry "r2" 10);
    "r2.failed_retry.depth_100",
      (fun () -> R2_workloads.failed_retry "r2" 100);
    "r1b.changed.depth_1", (fun () -> R1b_workloads.changed "r1b" 1);
    "r1b.changed.depth_10", (fun () -> R1b_workloads.changed "r1b" 10);
    "r1b.changed.depth_100", (fun () -> R1b_workloads.changed "r1b" 100);
    "r1b.cutoff.depth_10", (fun () -> R1b_workloads.cutoff "r1b" 10);
    "r1b.fan_in.diamond", (fun () -> R1b_workloads.fan_in "r1b");
    "r1b.failed_retry.depth_1",
      (fun () -> R1b_workloads.failed_retry "r1b" 1);
    "r1b.failed_retry.depth_10",
      (fun () -> R1b_workloads.failed_retry "r1b" 10);
    "r1b.failed_retry.depth_100",
      (fun () -> R1b_workloads.failed_retry "r1b" 100);
    "r1m.changed.depth_1", (fun () -> make_r1m_changed 1);
    "r1m.changed.depth_10", (fun () -> make_r1m_changed 10);
    "r1m.changed.depth_100", (fun () -> make_r1m_changed 100);
    "r1m.cutoff.depth_10", (fun () -> R1m_workloads.cutoff "r1m" 10);
    "r1m.fan_in.diamond", (fun () -> R1m_workloads.fan_in "r1m");
    "r1m.failed_retry.depth_1",
      (fun () -> R1m_workloads.failed_retry "r1m" 1);
    "r1m.failed_retry.depth_10",
      (fun () -> R1m_workloads.failed_retry "r1m" 10);
    "r1m.failed_retry.depth_100",
      (fun () -> R1m_workloads.failed_retry "r1m" 100);
    "r2m.changed.depth_1", (fun () -> make_r2m_changed 1);
    "r2m.changed.depth_10", (fun () -> make_r2m_changed 10);
    "r2m.changed.depth_100", (fun () -> make_r2m_changed 100);
    "r2m.cutoff.depth_10", (fun () -> R2m_workloads.cutoff "r2m" 10);
    "r2m.fan_in.diamond", (fun () -> R2m_workloads.fan_in "r2m");
    "r2m.failed_retry.depth_1",
      (fun () -> R2m_workloads.failed_retry "r2m" 1);
    "r2m.failed_retry.depth_10",
      (fun () -> R2m_workloads.failed_retry "r2m" 10);
    "r2m.failed_retry.depth_100",
      (fun () -> R2m_workloads.failed_retry "r2m" 100);
    "r1w.changed.depth_10", (fun () -> R1w_workloads.changed "r1w" 10);
    "r1a.changed.depth_10", (fun () -> R1a_workloads.changed "r1a" 10);
    "r1a.changed.depth_100", (fun () -> R1a_workloads.changed "r1a" 100);
    "r1n.changed.depth_1", (fun () -> R1n_workloads.changed "r1n" 1);
    "r1n.changed.depth_10", (fun () -> R1n_workloads.changed "r1n" 10);
    "r1n.changed.depth_100", (fun () -> R1n_workloads.changed "r1n" 100);
    "r1n.cutoff.depth_10", (fun () -> R1n_workloads.cutoff "r1n" 10);
    "r1i.changed.depth_1", (fun () -> R1i_workloads.changed "r1i" 1);
    "r1i.changed.depth_10", (fun () -> R1i_workloads.changed "r1i" 10);
    "r1i.changed.depth_100", (fun () -> R1i_workloads.changed "r1i" 100);
    "r1i.cutoff.depth_10", (fun () -> R1i_workloads.cutoff "r1i" 10);
    "r1i.fan_in.diamond", (fun () -> R1i_workloads.fan_in "r1i");
    "r1i.failed_retry.depth_1",
      (fun () -> R1i_workloads.failed_retry "r1i" 1);
    "r1i.failed_retry.depth_10",
      (fun () -> R1i_workloads.failed_retry "r1i" 10);
    "r1i.failed_retry.depth_100",
      (fun () -> R1i_workloads.failed_retry "r1i" 100);
    "r06.changed.depth_1", (fun () -> make_r06_changed 1);
    "r06.changed.depth_10", (fun () -> make_r06_changed 10);
    "r06.changed.depth_100", (fun () -> make_r06_changed 100);
    "r06.cutoff.depth_10", (fun () -> make_r06_cutoff 10);
    "incremental.raw.changed.depth_1",
      (fun () -> make_incremental_changed 1);
    "incremental.raw.changed.depth_10",
      (fun () -> make_incremental_changed 10);
    "incremental.raw.changed.depth_100",
      (fun () -> make_incremental_changed 100);
    "incremental.raw.cutoff.depth_10",
      (fun () -> make_incremental_cutoff 10);
  ]

let parse_args () =
  let rec loop only samples check = function
    | [] -> only, samples, check
    | "--only" :: name :: rest -> loop (Some name) samples check rest
    | "--samples" :: count :: rest ->
        loop only (int_of_string count) check rest
    | "--check" :: rest -> loop only samples true rest
    | arg :: _ -> invalid_arg ("unknown argument: " ^ arg)
  in
  loop None 9 false (List.tl (Array.to_list Sys.argv))

let () =
  let only, sample_count, check = parse_args () in
  if check then (
    R1_checks.run "R1";
    R2_checks.run "R2";
    R1b_checks.run "R1b";
    R1m_checks.run "R1m";
    R2m_checks.run "R2m";
    R1w_checks.run "R1w";
    R1i_checks.run "R1i";
    check_r1b_retention_bound ();
    check_r3_counterexample ();
    check_slot_clearing_allocation ();
    Printf.printf "all correctness checks passed\n%!")
  else
    match only with
    | None -> invalid_arg "use --check or --only NAME"
    | Some selected ->
        let workload =
          match List.assoc_opt selected candidates with
          | None -> invalid_arg "unknown workload"
          | Some make -> make ()
        in
        Printf.printf "name,operations,sample,wall_ns,allocated_words\n%!";
        measure ~sample_count workload
