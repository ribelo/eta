(* PROTOTYPE: This executable compares private heterogeneous value stores on the
   accepted synchronous Signal kernel. It is not production Signal code. *)

exception Injected_failure

type stabilization = Quiescent | Committed
type error = Defect of exn | Reentrant_stabilization
type boxed = { number : int } [@@boxed]
type heterogeneous = { text : string }

let failf format = Printf.ksprintf failwith format
external consume_box : boxed -> unit = "eta_signal_consume_box" [@@noalloc]

module type VALUE = sig
  type 'a t
  type packed

  val variable : 'a -> 'a t
  val map : ?cutoff:('b -> 'b -> bool) -> ('a -> 'b) -> 'a t -> 'b t
  val pack : 'a t -> packed
  val read : 'a t -> 'a
  val set_source : 'a t -> 'a -> bool

  val evaluate :
    packed -> pass:int -> slot:int -> record:(int -> unit) -> bool

  val restore : packed -> pass:int -> unit
  val written_in : packed -> int
end

module Embedded : VALUE = struct
  type 'a node = {
    mutable current : 'a;
    mutable undo : 'a;
    mutable written_in : int;
    mutable accepted : 'a;
    source : bool;
    compute : unit -> 'a;
    cutoff : 'a -> 'a -> bool;
  }

  and 'a t = 'a node
  type packed = Node : 'a node -> packed

  let variable initial =
    let rec node =
      {
        current = initial;
        undo = initial;
        written_in = -1;
        accepted = initial;
        source = true;
        compute = (fun () -> node.accepted);
        cutoff = ( == );
      }
    in
    node

  let map ?(cutoff = ( == )) f child =
    let initial = f child.current in
    {
      current = initial;
      undo = initial;
      written_in = -1;
      accepted = initial;
      source = false;
      compute = (fun () -> f child.current);
      cutoff;
    }

  let pack node = Node node
  let read node = node.current

  let set_source node value =
    if not node.source then invalid_arg "set_source on map";
    if node.accepted == value then false
    else (
      node.accepted <- value;
      true)

  let evaluate (Node node) ~pass ~slot ~record =
    let candidate = node.compute () in
    if node.cutoff node.current candidate then false
    else (
      if node.written_in <> pass then (
        record slot;
        node.undo <- node.current;
        node.written_in <- pass);
      node.current <- candidate;
      true)

  let restore (Node node) ~pass =
    if node.written_in <> pass then
      failwith "embedded rollback stamp mismatch";
    node.current <- node.undo;
    node.written_in <- -1

  let written_in (Node node) = node.written_in
end

module Erased : VALUE = struct
  type node = {
    mutable current : Obj.t;
    mutable undo : Obj.t;
    mutable written_in : int;
    mutable accepted : Obj.t;
    source : bool;
    compute : unit -> Obj.t;
    cutoff : Obj.t -> Obj.t -> bool;
  }

  type 'a t = node
  type packed = node

  let variable initial =
    let initial = Obj.repr initial in
    let rec node =
      {
        current = initial;
        undo = initial;
        written_in = -1;
        accepted = initial;
        source = true;
        compute = (fun () -> node.accepted);
        cutoff = ( == );
      }
    in
    node

  let map ?(cutoff = ( == )) f child =
    let compute () = Obj.repr (f (Obj.obj child.current)) in
    let initial = compute () in
    {
      current = initial;
      undo = initial;
      written_in = -1;
      accepted = initial;
      source = false;
      compute;
      cutoff =
        (fun old candidate -> cutoff (Obj.obj old) (Obj.obj candidate));
    }

  let pack node = node
  let read node = Obj.obj node.current

  let set_source node value =
    if not node.source then invalid_arg "set_source on map";
    let value = Obj.repr value in
    if node.accepted == value then false
    else (
      node.accepted <- value;
      true)

  let evaluate node ~pass ~slot ~record =
    let candidate = node.compute () in
    if node.cutoff node.current candidate then false
    else (
      if node.written_in <> pass then (
        record slot;
        node.undo <- node.current;
        node.written_in <- pass);
      node.current <- candidate;
      true)

  let restore node ~pass =
    if node.written_in <> pass then failwith "erased rollback stamp mismatch";
    node.current <- node.undo;
    node.written_in <- -1

  let written_in node = node.written_in
end

module Closure_packed : VALUE = struct
  type 'a cell = {
    mutable current : 'a;
    mutable undo : 'a;
    mutable written_in : int;
  }

  type packed = {
    evaluate : pass:int -> slot:int -> record:(int -> unit) -> bool;
    restore : pass:int -> unit;
    written_in : unit -> int;
  }

  type 'a t = {
    cell : 'a cell;
    accepted : 'a ref;
    source : bool;
    packed : packed;
  }

  let make ~source ~initial ~accepted ~compute ~cutoff =
    let cell = { current = initial; undo = initial; written_in = -1 } in
    let evaluate ~pass ~slot ~record =
      let candidate = compute () in
      if cutoff cell.current candidate then false
      else (
        if cell.written_in <> pass then (
          record slot;
          cell.undo <- cell.current;
          cell.written_in <- pass);
        cell.current <- candidate;
        true)
    in
    let restore ~pass =
      if cell.written_in <> pass then
        failwith "closure rollback stamp mismatch";
      cell.current <- cell.undo;
      cell.written_in <- -1
    in
    let packed =
      {
        evaluate;
        restore;
        written_in = (fun () -> cell.written_in);
      }
    in
    { cell; accepted; source; packed }

  let variable initial =
    let accepted = ref initial in
    make ~source:true ~initial ~accepted
      ~compute:(fun () -> !accepted) ~cutoff:( == )

  let map ?(cutoff = ( == )) f child =
    let initial = f child.cell.current in
    make ~source:false ~initial ~accepted:(ref initial)
      ~compute:(fun () -> f child.cell.current) ~cutoff

  let pack value = value.packed
  let read value = value.cell.current

  let set_source value candidate =
    if not value.source then invalid_arg "set_source on map";
    if !(value.accepted) == candidate then false
    else (
      value.accepted := candidate;
      true)

  let evaluate value = value.evaluate
  let restore value = value.restore
  let written_in value = value.written_in ()
end

module type KERNEL = sig
  type graph
  type 'a signal
  type 'a var

  val create : unit -> graph
  val var : graph -> 'a -> 'a var
  val watch : 'a var -> 'a signal
  val map :
    ?cutoff:('b -> 'b -> bool) -> ('a -> 'b) -> 'a signal -> 'b signal
  val set : graph -> 'a var -> 'a -> unit
  val demand : 'a signal -> unit
  val stabilize : graph -> (stabilization, error) result
  val stabilize_unit : graph -> unit
  val value : 'a signal -> 'a
  val journal_high_water : graph -> int
  val journal_prefix_is_immediate : graph -> bool
end

module Make (Value : VALUE) : KERNEL = struct
  type node = {
    graph : graph;
    slot : int;
    height : int;
    value : Value.packed;
    mutable parent : node option;
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
    mutable arena : node option array;
    mutable arena_length : int;
    mutable journal : int array;
    mutable journal_length : int;
    mutable journal_high_water : int;
    record_slot : int -> unit;
    mutable admissions : int array;
    mutable admission_length : int;
  }

  type 'a signal = { node : node; typed : 'a Value.t }
  type 'a var = 'a signal

  let create () =
    let rec graph =
      {
        pass = 0;
        running = false;
        highest = -1;
        heads = Array.make 4 None;
        tails = Array.make 4 None;
        arena = Array.make 16 None;
        arena_length = 0;
        journal = Array.make 16 0;
        journal_length = 0;
        journal_high_water = 0;
        record_slot =
          (fun slot ->
            if graph.journal_length = Array.length graph.journal then (
              let next = Array.make (Array.length graph.journal * 2) 0 in
              Array.blit graph.journal 0 next 0 (Array.length graph.journal);
              graph.journal <- next);
            graph.journal.(graph.journal_length) <- slot;
            graph.journal_length <- graph.journal_length + 1;
            if graph.journal_length > graph.journal_high_water then
              graph.journal_high_water <- graph.journal_length);
        admissions = Array.make 4 0;
        admission_length = 0;
      }
    in
    graph

  let grow_options values =
    let next = Array.make (Array.length values * 2) None in
    Array.blit values 0 next 0 (Array.length values);
    next

  let grow_ints values =
    let next = Array.make (Array.length values * 2) 0 in
    Array.blit values 0 next 0 (Array.length values);
    next

  let ensure_height graph height =
    while height >= Array.length graph.heads do
      graph.heads <- grow_options graph.heads;
      graph.tails <- grow_options graph.tails
    done

  let add_node graph ~height typed =
    ensure_height graph height;
    if graph.arena_length = Array.length graph.arena then
      graph.arena <- grow_options graph.arena;
    let slot = graph.arena_length in
    let node =
      {
        graph;
        slot;
        height;
        value = Value.pack typed;
        parent = None;
        necessary = false;
        queued_at = -1;
        queue_next = None;
        admitted = false;
      }
    in
    graph.arena.(slot) <- Some node;
    graph.arena_length <- slot + 1;
    { node; typed }

  let var graph initial = add_node graph ~height:0 (Value.variable initial)
  let watch variable = variable

  let map ?cutoff f child =
    let signal =
      add_node child.node.graph ~height:(child.node.height + 1)
        (Value.map ?cutoff f child.typed)
    in
    if child.node.parent <> None then
      invalid_arg "PROTOTYPE supports one static parent";
    child.node.parent <- Some signal.node;
    signal

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
      if graph.admission_length = Array.length graph.admissions then
        graph.admissions <- grow_ints graph.admissions;
      node.admitted <- true;
      graph.admissions.(graph.admission_length) <- node.slot;
      graph.admission_length <- graph.admission_length + 1)

  let set graph variable value =
    if variable.node.graph != graph then invalid_arg "graph mismatch";
    if Value.set_source variable.typed value then (
      retain_admission variable.node;
      enqueue variable.node)

  let rec demand_node node =
    if not node.necessary then (
      node.necessary <- true;
      if node.height = 0 then (
        retain_admission node;
        enqueue node))

  let demand signal =
    let rec descend node =
      demand_node node;
      if node.height > 0 then
        (* A chain has one child at the preceding arena slot. *)
        match node.graph.arena.(node.slot - 1) with
        | Some child -> descend child
        | None -> failwith "missing chain child"
    in
    descend signal.node

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
    let changed =
      Value.evaluate node.value ~pass:graph.pass ~slot:node.slot
        ~record:graph.record_slot
    in
    if changed then (
      match node.parent with
      | Some parent when parent.necessary -> ignore (recompute parent)
      | _ -> ());
    changed

  let resolve graph slot =
    match graph.arena.(slot) with
    | Some node -> node
    | None -> failwith "active value journal resolved to an empty slot"

  let clear_admissions graph =
    for index = 0 to graph.admission_length - 1 do
      (resolve graph graph.admissions.(index)).admitted <- false
    done;
    graph.admission_length <- 0

  let replay_admissions graph =
    for index = 0 to graph.admission_length - 1 do
      enqueue (resolve graph graph.admissions.(index))
    done

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

  let rollback graph =
    for index = graph.journal_length - 1 downto 0 do
      let node = resolve graph graph.journal.(index) in
      Value.restore node.value ~pass:graph.pass
    done;
    graph.journal_length <- 0

  let run_stabilization graph =
    if graph.running then raise Exit
    else
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
          graph.journal_length <- 0;
          clear_admissions graph;
          graph.pass <- graph.pass + 1;
          graph.running <- false;
          changed
      | exception exn ->
          rollback graph;
          drain_frontier graph;
          graph.pass <- graph.pass + 1;
          replay_admissions graph;
          graph.running <- false;
          raise exn

  let stabilize graph =
    match run_stabilization graph with
    | changed -> Ok (if changed then Committed else Quiescent)
    | exception Exit -> Error Reentrant_stabilization
    | exception exn -> Error (Defect exn)

  let stabilize_unit graph = ignore (run_stabilization graph)

  let value signal = Value.read signal.typed
  let journal_high_water graph = graph.journal_high_water

  let journal_prefix_is_immediate graph =
    let answer = ref true in
    for index = 0 to graph.journal_high_water - 1 do
      if not (Obj.is_int (Obj.repr graph.journal.(index))) then answer := false
    done;
    !answer
end

module A = Make (Embedded)
module B = Make (Erased)
module C = Make (Closure_packed)

(* Integer-specialized R1i timing control. Its public shape is deliberately
   narrow. It retains the same direct unary scheduler, sparse immediate journal,
   O(1) commit, and reverse rollback. *)
module Int_control = struct
  type node = {
    graph : graph;
    slot : int;
    height : int;
    compute : unit -> int;
    mutable current : int;
    mutable undo : int;
    mutable written_in : int;
    mutable parent : node option;
    mutable necessary : bool;
    mutable queued_at : int;
    mutable queue_next : node option;
    mutable admitted : bool;
  }

  and graph = {
    mutable pass : int;
    mutable highest : int;
    mutable heads : node option array;
    mutable tails : node option array;
    mutable arena : node option array;
    mutable arena_length : int;
    mutable journal : int array;
    mutable journal_length : int;
    mutable admissions : int array;
    mutable admission_length : int;
  }

  type var = { accepted : int ref; watch : node }

  let grow_options values =
    let next = Array.make (Array.length values * 2) None in
    Array.blit values 0 next 0 (Array.length values);
    next

  let grow_ints values =
    let next = Array.make (Array.length values * 2) 0 in
    Array.blit values 0 next 0 (Array.length values);
    next

  let create () =
    {
      pass = 0;
      highest = -1;
      heads = Array.make 4 None;
      tails = Array.make 4 None;
      arena = Array.make 16 None;
      arena_length = 0;
      journal = Array.make 16 0;
      journal_length = 0;
      admissions = Array.make 4 0;
      admission_length = 0;
    }

  let add graph ~height ~compute ~initial =
    while height >= Array.length graph.heads do
      graph.heads <- grow_options graph.heads;
      graph.tails <- grow_options graph.tails
    done;
    if graph.arena_length = Array.length graph.arena then
      graph.arena <- grow_options graph.arena;
    let slot = graph.arena_length in
    let node =
      {
        graph;
        slot;
        height;
        compute;
        current = initial;
        undo = initial;
        written_in = -1;
        parent = None;
        necessary = false;
        queued_at = -1;
        queue_next = None;
        admitted = false;
      }
    in
    graph.arena.(slot) <- Some node;
    graph.arena_length <- slot + 1;
    node

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
          graph.tails.(height) <- Some node)

  let chain depth =
    let graph = create () in
    let accepted = ref 0 in
    let source = add graph ~height:0 ~compute:(fun () -> !accepted) ~initial:0 in
    let rec loop remaining child =
      if remaining = 0 then child
      else
        let initial = child.current + 1 in
        let parent =
          add graph ~height:(child.height + 1)
            ~compute:(fun () -> child.current + 1) ~initial
        in
        child.parent <- Some parent;
        loop (remaining - 1) parent
    in
    let output = loop depth source in
    Array.iter
      (function Some node -> node.necessary <- true | None -> ())
      graph.arena;
    source.admitted <- true;
    graph.admissions.(0) <- source.slot;
    graph.admission_length <- 1;
    enqueue source;
    graph, { accepted; watch = source }, output

  let resolve graph slot =
    match graph.arena.(slot) with
    | Some node -> node
    | None -> failwith "control journal resolved to empty slot"

  let set graph var value =
    if !(var.accepted) <> value then (
      var.accepted := value;
      if not var.watch.admitted then (
        var.watch.admitted <- true;
        graph.admissions.(graph.admission_length) <- var.watch.slot;
        graph.admission_length <- graph.admission_length + 1);
      enqueue var.watch)

  let record node =
    let graph = node.graph in
    if node.written_in <> graph.pass then (
      if graph.journal_length = Array.length graph.journal then
        graph.journal <- grow_ints graph.journal;
      graph.journal.(graph.journal_length) <- node.slot;
      graph.journal_length <- graph.journal_length + 1;
      node.undo <- node.current;
      node.written_in <- graph.pass)

  let rec recompute node =
    let candidate = node.compute () in
    if node.current = candidate then false
    else (
      record node;
      node.current <- candidate;
      match node.parent with
      | Some parent ->
          ignore (recompute parent);
          true
      | None -> true)

  let pop graph height =
    match graph.heads.(height) with
    | None -> None
    | Some node ->
        graph.heads.(height) <- node.queue_next;
        if graph.heads.(height) = None then graph.tails.(height) <- None;
        node.queue_next <- None;
        Some node

  let stabilize_unit graph =
    let rec drain height =
      if height <= graph.highest then
        match pop graph height with
        | None -> drain (height + 1)
        | Some node ->
            ignore (recompute node);
            drain height
    in
    match drain 0 with
    | () ->
        graph.highest <- -1;
        graph.journal_length <- 0;
        for index = 0 to graph.admission_length - 1 do
          (resolve graph graph.admissions.(index)).admitted <- false
        done;
        graph.admission_length <- 0;
        graph.pass <- graph.pass + 1
    | exception exn ->
        for index = graph.journal_length - 1 downto 0 do
          let node = resolve graph graph.journal.(index) in
          node.current <- node.undo;
          node.written_in <- -1
        done;
        graph.journal_length <- 0;
        for height = 0 to graph.highest do
          let rec clear () =
            match pop graph height with
            | None -> ()
            | Some node ->
                node.queued_at <- -1;
                clear ()
          in
          clear ()
        done;
        graph.highest <- -1;
        graph.pass <- graph.pass + 1;
        for index = 0 to graph.admission_length - 1 do
          enqueue (resolve graph graph.admissions.(index))
        done;
        raise exn

  let value node = node.current
end

type workload = {
  name : string;
  graph_size : int;
  run_batch : int -> unit;
  check : unit -> unit;
}

let make_control_int depth =
  let graph, source, output = Int_control.chain depth in
  Int_control.stabilize_unit graph;
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Int_control.set graph source !next;
      Int_control.stabilize_unit graph
    done
  in
  {
    name = Printf.sprintf "control.int.changed.depth_%d" depth;
    graph_size = depth + 1;
    run_batch;
    check =
      (fun () ->
        if Int_control.value output <> !next + depth then
          failf "integer control depth %d mismatch" depth);
  }

let promote value =
  let holder = ref value in
  Gc.full_major ();
  Sys.opaque_identity !holder

module Workloads (K : KERNEL) = struct
  let int_changed prefix depth =
    let graph = K.create () in
    let source = K.var graph 0 in
    let rec loop remaining current =
      if remaining = 0 then current
      else loop (remaining - 1) (K.map (( + ) 1) current)
    in
    let output = loop depth (K.watch source) in
    K.demand output;
    K.stabilize_unit graph;
    let next = ref 0 in
    let run_batch operations =
      for _ = 1 to operations do
        incr next;
        K.set graph source !next;
        K.stabilize_unit graph
      done
    in
    {
      name = Printf.sprintf "%s.int.changed.depth_%d" prefix depth;
      graph_size = depth + 1;
      run_batch;
      check =
        (fun () ->
          if K.value output <> !next + depth then
            failf "%s int depth %d mismatch" prefix depth);
    }

  let boxed_changed prefix depth =
    let left = promote { number = 0 } in
    let right = promote { number = 1 } in
    let graph = K.create () in
    let source = K.var graph left in
    let rec loop remaining current =
      if remaining = 0 then current
      else loop (remaining - 1) (K.map Fun.id current)
    in
    let output = loop depth (K.watch source) in
    K.demand output;
    K.stabilize_unit graph;
    let next = ref false in
    let expected = ref left in
    let run_batch operations =
      for _ = 1 to operations do
        next := not !next;
        expected := if !next then right else left;
        K.set graph source !expected;
        K.stabilize_unit graph
      done
    in
    {
      name = Printf.sprintf "%s.boxed_old.changed.depth_%d" prefix depth;
      graph_size = depth + 1;
      run_batch;
      check =
        (fun () ->
          if K.value output != !expected then
            failf "%s boxed depth %d identity mismatch" prefix depth);
    }

  let fresh_changed prefix =
    let initial = promote { number = 0 } in
    let graph = K.create () in
    let source = K.var graph initial in
    let output = K.map Fun.id (K.watch source) in
    K.demand output;
    K.stabilize_unit graph;
    let next = ref 0 in
    let run_batch operations =
      for _ = 1 to operations do
        incr next;
        let value = { number = !next } in
        K.set graph source value;
        K.stabilize_unit graph
      done
    in
    {
      name = prefix ^ ".boxed_young.changed.depth_1";
      graph_size = 2;
      run_batch;
      check =
        (fun () ->
          if (K.value output).number <> !next then
            failf "%s fresh boxed value mismatch" prefix);
    }
end

module A_workloads = Workloads (A)
module B_workloads = Workloads (B)
module C_workloads = Workloads (C)

let make_construction_control () =
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      let value = { number = !next } in
      consume_box value
    done
  in
  {
    name = "control.boxed_young.construct";
    graph_size = 0;
    run_batch;
    check =
      (fun () ->
        if !next = 0 then failwith "construction control did not run");
  }

let make_old_ref_control () =
  let old_left = promote { number = 0 } in
  let old_right = promote { number = 1 } in
  let target = ref old_left in
  Gc.full_major ();
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      target := if !next land 1 = 0 then old_left else old_right
    done
  in
  {
    name = "control.boxed_old.old_ref_store";
    graph_size = 1;
    run_batch;
    check = (fun () -> ignore (Sys.opaque_identity !target));
  }

let make_young_ref_control () =
  let initial = promote { number = 0 } in
  let target = ref initial in
  Gc.full_major ();
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      let value = { number = !next } in
      consume_box value;
      target := value
    done
  in
  {
    name = "control.boxed_young.old_ref_store";
    graph_size = 1;
    run_batch;
    check =
      (fun () ->
        if (!target).number <> !next then
          failwith "young reference control mismatch");
  }

let make_incremental_int depth =
  let module Incr = Incremental.Make () in
  let source = Incr.Var.create 0 in
  let rec loop remaining signal =
    if remaining = 0 then signal
    else loop (remaining - 1) (Incr.map signal ~f:(( + ) 1))
  in
  let output = loop depth (Incr.Var.watch source) in
  let observer = Incr.observe output in
  Incr.stabilize ();
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Incr.Var.set source !next;
      Incr.stabilize ()
    done
  in
  {
    name = Printf.sprintf "incremental.raw.int.changed.depth_%d" depth;
    graph_size = depth + 1;
    run_batch;
    check =
      (fun () ->
        if Incr.Observer.value_exn observer <> !next + depth then
          failwith "Incremental int mismatch");
  }

let make_incremental_boxed depth =
  let module Incr = Incremental.Make () in
  let left = promote { number = 0 } in
  let right = promote { number = 1 } in
  let source = Incr.Var.create left in
  let rec loop remaining signal =
    if remaining = 0 then signal
    else loop (remaining - 1) (Incr.map signal ~f:Fun.id)
  in
  let output = loop depth (Incr.Var.watch source) in
  let observer = Incr.observe output in
  Incr.stabilize ();
  let next = ref false in
  let expected = ref left in
  let run_batch operations =
    for _ = 1 to operations do
      next := not !next;
      expected := if !next then right else left;
      Incr.Var.set source !expected;
      Incr.stabilize ()
    done
  in
  {
    name = Printf.sprintf "incremental.raw.boxed_old.changed.depth_%d" depth;
    graph_size = depth + 1;
    run_batch;
    check =
      (fun () ->
        if Incr.Observer.value_exn observer != !expected then
          failwith "Incremental boxed identity mismatch");
  }

let assert_error = function
  | Error (Defect Injected_failure) -> ()
  | Error (Defect exn) -> raise exn
  | Error Reentrant_stabilization -> failwith "unexpected reentry"
  | Ok _ -> failwith "expected injected failure"

let check_candidate name (module K : KERNEL) =
  let graph = K.create () in
  let source = K.var graph 1 in
  let as_string = K.map string_of_int (K.watch source) in
  let record = K.map (fun text -> { text }) as_string in
  K.demand record;
  K.stabilize_unit graph;
  K.set graph source 42;
  K.stabilize_unit graph;
  if K.value as_string <> "42" || (K.value record).text <> "42" then
    failf "%s heterogeneous propagation failed" name;

  let graph = K.create () in
  let source = K.var graph 7 in
  let as_string = K.map string_of_int (K.watch source) in
  let as_record = K.map (fun text -> { text }) as_string in
  let fail_once = ref false in
  let output =
    K.map
      (fun value ->
        if !fail_once then (
          fail_once := false;
          raise Injected_failure);
        value)
      as_record
  in
  K.demand output;
  K.stabilize_unit graph;
  let old_string = K.value as_string in
  let old_record = K.value as_record in
  let old_output = K.value output in
  fail_once := true;
  K.set graph source 8;
  assert_error (K.stabilize graph);
  if K.value (K.watch source) <> 7
     || K.value as_string != old_string
     || K.value as_record != old_record
     || K.value output != old_output
  then failf "%s did not restore heterogeneous values and identity" name;
  if not (K.journal_prefix_is_immediate graph) then
    failf "%s journal retained a pointer" name;
  if K.journal_high_water graph <> 3 then
    failf "%s expected three first-written rollback entries" name;
  (match K.stabilize graph with
  | Ok Committed -> ()
  | _ -> failf "%s retry did not commit" name);
  if K.value (K.watch source) <> 8 || K.value as_string <> "8"
     || (K.value as_record).text <> "8"
  then failf "%s retry value mismatch" name

let check_first_write name (module V : VALUE) =
  let value = V.variable 0 in
  let packed = V.pack value in
  let records = ref 0 in
  let record slot =
    if slot <> 7 then failf "%s first-write slot mismatch" name;
    incr records
  in
  ignore (V.set_source value 1);
  if not (V.evaluate packed ~pass:3 ~slot:7 ~record) then
    failf "%s first write did not change" name;
  ignore (V.set_source value 2);
  if not (V.evaluate packed ~pass:3 ~slot:7 ~record) then
    failf "%s second write did not change" name;
  if !records <> 1 then
    failf "%s recorded %d writes in one pass" name !records;
  V.restore packed ~pass:3;
  if V.read value <> 0 then failf "%s first-write undo mismatch" name

let check_cutoff_baseline name (module K : KERNEL) =
  let graph = K.create () in
  let source = K.var graph 0 in
  let fail_once = ref false in
  let cutoff_calls = ref [] in
  let gate =
    K.map
      ~cutoff:(fun published candidate ->
        cutoff_calls := (published, candidate) :: !cutoff_calls;
        candidate = 2)
      Fun.id (K.watch source)
  in
  let output =
    K.map
      (fun value ->
        if !fail_once then (
          fail_once := false;
          raise Injected_failure);
        value)
      gate
  in
  K.demand output;
  K.stabilize_unit graph;
  fail_once := true;
  K.set graph source 1;
  assert_error (K.stabilize graph);
  K.set graph source 2;
  (match K.stabilize graph with
  | Ok Committed -> ()
  | _ -> failf "%s cutoff retry did not commit source" name);
  if K.value gate <> 0 || K.value output <> 0 then
    failf "%s cutoff exposed a failed value" name;
  if List.rev !cutoff_calls <> [ 0, 1; 0, 2 ] then
    failf "%s cutoff did not retain the published baseline" name

let allocated_words operations run =
  Gc.full_major ();
  let before_minor, before_promoted, before_major = Gc.counters () in
  run operations;
  let after_minor, after_promoted, after_major = Gc.counters () in
  ((after_minor -. before_minor)
   +. (after_major -. before_major)
   -. (after_promoted -. before_promoted))
  /. float_of_int operations

let check_allocation name make =
  let rows =
    List.map
      (fun depth ->
        let workload = make depth in
        workload.run_batch 10_000;
        workload.check ();
        let words = allocated_words 100_000 workload.run_batch in
        workload.check ();
        depth, words)
      [ 1; 10; 100 ]
  in
  List.iter
    (fun (depth, words) ->
      if Float.abs (words -. 4.) > 0.01 then
        failf "%s depth %d allocated %.6f words, expected 4" name depth words)
    rows

let check_semantics () =
  List.iter
    (fun (name, value) -> check_first_write name value)
    [ "a", (module Embedded : VALUE); "b", (module Erased : VALUE);
      "c", (module Closure_packed : VALUE) ];
  List.iter
    (fun (name, kernel) ->
      check_candidate name kernel;
      check_cutoff_baseline name kernel)
    [ "a", (module A : KERNEL); "b", (module B : KERNEL);
      "c", (module C : KERNEL) ];
  check_allocation "a.int" (A_workloads.int_changed "a");
  check_allocation "b.int" (B_workloads.int_changed "b");
  check_allocation "c.int" (C_workloads.int_changed "c");
  check_allocation "a.boxed" (A_workloads.boxed_changed "a");
  check_allocation "b.boxed" (B_workloads.boxed_changed "b");
  check_allocation "c.boxed" (C_workloads.boxed_changed "c");
  Printf.printf "semantic and allocation checks passed\n%!"

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
    Printf.printf "%s,%d,%d,%d,%.6f,%.6f\n%!" workload.name
      workload.graph_size operations sample wall_ns allocated_words
  done

let candidates =
  let depths = [ 1; 10; 100 ] in
  let rows = ref [] in
  List.iter
    (fun depth ->
      rows :=
        (Printf.sprintf "incremental.raw.int.changed.depth_%d" depth,
         fun () -> make_incremental_int depth)
        :: !rows;
      rows :=
        (Printf.sprintf "control.int.changed.depth_%d" depth,
         fun () -> make_control_int depth)
        :: !rows;
      rows :=
        ("a.int.changed.depth_" ^ string_of_int depth,
         fun () -> A_workloads.int_changed "a" depth)
        :: ("b.int.changed.depth_" ^ string_of_int depth,
            fun () -> B_workloads.int_changed "b" depth)
        :: ("c.int.changed.depth_" ^ string_of_int depth,
            fun () -> C_workloads.int_changed "c" depth)
        :: !rows;
      rows :=
        (Printf.sprintf "incremental.raw.boxed_old.changed.depth_%d" depth,
         fun () -> make_incremental_boxed depth)
        :: !rows;
      rows :=
        ("a.boxed_old.changed.depth_" ^ string_of_int depth,
         fun () -> A_workloads.boxed_changed "a" depth)
        :: ("b.boxed_old.changed.depth_" ^ string_of_int depth,
            fun () -> B_workloads.boxed_changed "b" depth)
        :: ("c.boxed_old.changed.depth_" ^ string_of_int depth,
            fun () -> C_workloads.boxed_changed "c" depth)
        :: !rows)
    depths;
  rows :=
    ("a.boxed_young.changed.depth_1",
     fun () -> A_workloads.fresh_changed "a")
    :: ("b.boxed_young.changed.depth_1",
        fun () -> B_workloads.fresh_changed "b")
    :: ("c.boxed_young.changed.depth_1",
        fun () -> C_workloads.fresh_changed "c")
    :: !rows;
  rows :=
    ("control.boxed_young.construct", make_construction_control)
    :: ("control.boxed_young.old_ref_store", make_young_ref_control)
    :: ("control.boxed_old.old_ref_store", make_old_ref_control)
    :: !rows;
  !rows

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
  if check then check_semantics ()
  else
    match only with
    | None -> invalid_arg "use --check or --only NAME"
    | Some selected ->
        let workload =
          match List.assoc_opt selected candidates with
          | None -> invalid_arg ("unknown workload: " ^ selected)
          | Some make -> make ()
        in
        Printf.printf
          "name,graph_size,operations,sample,wall_ns,allocated_words\n%!";
        measure ~sample_count workload
