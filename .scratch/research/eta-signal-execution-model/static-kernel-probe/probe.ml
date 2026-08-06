(* PROTOTYPE: This executable compares immutable plans with a retained,
   synchronous propagation kernel. It is not production Signal code. *)

module Plan = struct
  type operation = {
    compute : int -> int;
    cutoff : int -> int -> bool;
  }

  type snapshot = { revision : int; values : int array }

  type plan = {
    base_revision : int;
    prospective : int array;
  }

  type t = {
    operations : operation array;
    mutable snapshot : snapshot;
    mutable accepted : int;
  }

  let create_operations operations =
    let values = Array.make (Array.length operations) 0 in
    for index = 1 to Array.length operations - 1 do
      values.(index) <- operations.(index).compute values.(index - 1)
    done;
    { operations; snapshot = { revision = 0; values }; accepted = 0 }

  let create depth =
    create_operations
      (Array.init (depth + 1) (fun index ->
           if index = 0 then { compute = Fun.id; cutoff = Int.equal }
           else { compute = (( + ) 1); cutoff = Int.equal }))

  let create_cutoff depth =
    create_operations
      (Array.init (depth + 2) (fun index ->
           if index = 0 then { compute = Fun.id; cutoff = Int.equal }
           else if index = 1 then
             { compute = (fun _ -> 0); cutoff = Int.equal }
           else { compute = (( + ) 1); cutoff = Int.equal }))

  let set t value = t.accepted <- value

  let plan t =
    let prospective = Array.copy t.snapshot.values in
    let propagates =
      ref (not (t.operations.(0).cutoff t.snapshot.values.(0) t.accepted))
    in
    if !propagates then prospective.(0) <- t.accepted;
    let index = ref 1 in
    while !propagates && !index < Array.length t.operations do
      let operation = t.operations.(!index) in
      let candidate = operation.compute prospective.(!index - 1) in
      if operation.cutoff t.snapshot.values.(!index) candidate then
        propagates := false
      else prospective.(!index) <- candidate;
      incr index
    done;
    { base_revision = t.snapshot.revision; prospective }

  let commit t plan =
    if t.snapshot.revision <> plan.base_revision then
      invalid_arg "stale immutable plan";
    t.snapshot <-
      { revision = plan.base_revision + 1; values = plan.prospective }

  let stabilize t = commit t (plan t)

  let value t =
    t.snapshot.values.(Array.length t.snapshot.values - 1)
end

module Raw = struct
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

type workload = {
  name : string;
  run_batch : int -> unit;
  check : unit -> unit;
}

let failf format = Printf.ksprintf failwith format

let raw_chain depth =
  let graph = Raw.create () in
  let source = Raw.var graph 0 in
  let rec loop remaining signal =
    if remaining = 0 then signal
    else loop (remaining - 1) (Raw.map (( + ) 1) signal)
  in
  let output = loop depth (Raw.watch source) in
  let _demand = Raw.demand output in
  graph, source, output

let make_raw_changed depth =
  let graph, source, output = raw_chain depth in
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Raw.set graph source !next;
      ignore (Raw.stabilize graph)
    done
  in
  let check () =
    let observed = Raw.value output in
    let expected = !next + depth in
    if observed <> expected then
      failf "raw depth %d: expected %d, observed %d" depth expected observed
  in
  {
    name = Printf.sprintf "raw.changed.depth_%d" depth;
    run_batch;
    check;
  }

let make_plan_changed depth =
  let graph = Plan.create depth in
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Plan.set graph !next;
      Plan.stabilize graph
    done
  in
  let check () =
    let observed = Plan.value graph in
    let expected = !next + depth in
    if observed <> expected then
      failf "plan depth %d: expected %d, observed %d" depth expected observed
  in
  {
    name = Printf.sprintf "plan.changed.depth_%d" depth;
    run_batch;
    check;
  }

let make_plan_cutoff depth =
  let graph = Plan.create_cutoff depth in
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Plan.set graph !next;
      Plan.stabilize graph
    done
  in
  let check () =
    let observed = Plan.value graph in
    if observed <> depth then
      failf "plan cutoff: expected %d, observed %d" depth observed
  in
  {
    name = Printf.sprintf "plan.cutoff.depth_%d" depth;
    run_batch;
    check;
  }

let make_raw_cutoff depth =
  let graph = Raw.create () in
  let source = Raw.var graph 0 in
  let constant =
    Raw.map ~cutoff:Int.equal (fun _ -> 0) (Raw.watch source)
  in
  let rec loop remaining signal =
    if remaining = 0 then signal
    else loop (remaining - 1) (Raw.map (( + ) 1) signal)
  in
  let output = loop depth constant in
  let _demand = Raw.demand output in
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Raw.set graph source !next;
      ignore (Raw.stabilize graph)
    done
  in
  let check () =
    let observed = Raw.value output in
    if observed <> depth then
      failf "raw cutoff: expected %d, observed %d" depth observed
  in
  {
    name = Printf.sprintf "raw.cutoff.depth_%d" depth;
    run_batch;
    check;
  }

let make_raw_fan_in () =
  let graph = Raw.create () in
  let source = Raw.var graph 0 in
  let watched = Raw.watch source in
  let left = Raw.map (( + ) 1) watched in
  let right = Raw.map (( + ) 2) watched in
  let output = Raw.map2 ( + ) left right in
  let _demand = Raw.demand output in
  let next = ref 0 in
  let run_batch operations =
    for _ = 1 to operations do
      incr next;
      Raw.set graph source !next;
      ignore (Raw.stabilize graph)
    done
  in
  let check () =
    let observed = Raw.value output in
    let expected = (!next * 2) + 3 in
    if observed <> expected then
      failf "raw fan-in: expected %d, observed %d" expected observed
  in
  { name = "raw.fan_in.diamond"; run_batch; check }

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
    let expected = !next + depth in
    if !observed <> expected then
      failf "Incremental depth %d: expected %d, observed %d"
        depth expected !observed
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
    if !observed <> depth then
      failf "Incremental cutoff: expected %d, observed %d" depth !observed
  in
  {
    name = Printf.sprintf "incremental.raw.cutoff.depth_%d" depth;
    run_batch;
    check;
  }

let assert_int label expected actual =
  if actual <> expected then
    failf "%s: expected %d, observed %d" label expected actual

let check_semantics () =
  let graph, source, output = raw_chain 10 in
  Raw.reset_counts graph;
  Raw.set graph source 1;
  Raw.set graph source 2;
  assert_int "accepted source value" 2 (Raw.var_value source);
  assert_int "derived value before stabilization" 10 (Raw.value output);
  ignore (Raw.stabilize graph);
  assert_int "coalesced value" 12 (Raw.value output);
  let counts = Raw.counts graph in
  assert_int "coalesced admissions" 2 counts.admissions;
  assert_int "narrow claims" 11 counts.claims;
  assert_int "narrow dependency edges" 10 counts.dependency_edges;
  assert_int "narrow propagation edges" 10 counts.propagation_edges;
  assert_int "narrow evaluations" 10 counts.evaluations;
  assert_int "narrow cutoffs" 10 counts.cutoffs;

  Raw.reset_counts graph;
  Raw.set graph source 2;
  (match Raw.stabilize graph with
  | Ok Raw.Quiescent -> ()
  | Ok Raw.Committed -> failwith "equal source admission committed"
  | Error Raw.Static_kernel_error -> assert false);
  assert_int "quiescent admissions" 1 counts.admissions;
  assert_int "quiescent claims" 0 counts.claims;
  assert_int "quiescent dependency edges" 0 counts.dependency_edges;
  assert_int "quiescent propagation edges" 0 counts.propagation_edges;
  assert_int "quiescent evaluations" 0 counts.evaluations;
  assert_int "quiescent cutoffs" 0 counts.cutoffs;

  let plan_cutoff = Plan.create_cutoff 10 in
  Plan.set plan_cutoff 1;
  Plan.stabilize plan_cutoff;
  assert_int "plan cutoff" 10 (Plan.value plan_cutoff);

  let cutoff = make_raw_cutoff 10 in
  cutoff.run_batch 1;
  cutoff.check ();

  let graph = Raw.create () in
  let source = Raw.var graph 0 in
  let calls = ref [] in
  let output =
    Raw.map
      ~cutoff:(fun published candidate ->
        calls := (published, candidate) :: !calls;
        candidate = 1)
      Fun.id (Raw.watch source)
  in
  let _demand = Raw.demand output in
  Raw.set graph source 1;
  ignore (Raw.stabilize graph);
  assert_int "suppressed value" 0 (Raw.value output);
  Raw.set graph source 2;
  ignore (Raw.stabilize graph);
  assert_int "post-suppression value" 2 (Raw.value output);
  if List.rev !calls <> [ 0, 1; 0, 2 ] then
    failwith "cutoff did not retain the published baseline";

  let graph = Raw.create () in
  let source = Raw.var graph 1 in
  let order = ref 0 in
  let left =
    Raw.map
      (fun value ->
        order := (!order * 10) + 1;
        value + 1)
      (Raw.watch source)
  in
  let right =
    Raw.map
      (fun value ->
        order := (!order * 10) + 2;
        value + 2)
      (Raw.watch source)
  in
  let output =
    Raw.map2
      (fun left right ->
        order := (!order * 10) + 3;
        left + right)
      left right
  in
  let demand = Raw.demand output in
  order := 0;
  Raw.set graph source 2;
  ignore (Raw.stabilize graph);
  assert_int "fan-in value" 7 (Raw.value output);
  assert_int "dependency order" 123 !order;
  Raw.release demand;
  order := 0;
  Raw.set graph source 3;
  ignore (Raw.stabilize graph);
  assert_int "released demand work" 0 !order;
  let _demand = Raw.demand output in
  ignore (Raw.stabilize graph);
  assert_int "reactivated value" 9 (Raw.value output);

  let graph = Raw.create () in
  let left = Raw.var graph 0 in
  let right = Raw.var graph 0 in
  let output = Raw.map2 ( + ) (Raw.watch left) (Raw.watch right) in
  let _demand = Raw.demand output in
  ignore (Raw.stabilize graph);
  Raw.reset_counts graph;
  Raw.set graph left 1;
  ignore (Raw.stabilize graph);
  let counts = Raw.counts graph in
  assert_int "fan-in dependency edges" 2 counts.dependency_edges;
  assert_int "fan-in propagation edges" 1 counts.propagation_edges;

  let check_static_economics size =
    let graph = Raw.create () in
    let source = Raw.var graph 0 in
    let _ballast =
      Array.init (size - 1) (fun _ -> Raw.const graph 0)
    in
    let _demand = Raw.demand (Raw.watch source) in
    ignore (Raw.stabilize graph);
    Raw.reset_counts graph;
    Raw.set graph source 0;
    (match Raw.stabilize graph with
    | Ok Raw.Quiescent -> ()
    | Ok Raw.Committed -> failwith "quiescent ballast graph committed"
    | Error Raw.Static_kernel_error -> assert false);
    let counts = Raw.counts graph in
    assert_int "ballast quiescent admissions" 1 counts.admissions;
    assert_int "ballast quiescent claims" 0 counts.claims;
    assert_int "ballast quiescent dependency edges" 0
      counts.dependency_edges;
    assert_int "ballast quiescent propagation edges" 0
      counts.propagation_edges;

    let graph, source, output = raw_chain 10 in
    let _ballast =
      Array.init (size - 11) (fun _ -> Raw.const graph 0)
    in
    ignore (Raw.stabilize graph);
    Raw.reset_counts graph;
    Raw.set graph source 1;
    ignore (Raw.stabilize graph);
    let counts = Raw.counts graph in
    assert_int "ballast narrow value" 11 (Raw.value output);
    assert_int "ballast narrow claims" 11 counts.claims;
    assert_int "ballast narrow dependency edges" 10
      counts.dependency_edges;
    assert_int "ballast narrow propagation edges" 10
      counts.propagation_edges;
    assert_int "ballast narrow evaluations" 10 counts.evaluations;
    assert_int "ballast narrow cutoffs" 10 counts.cutoffs;

    let affected = (size - 1) / 2 in
    let graph, source, output = raw_chain affected in
    let _ballast =
      Array.init (size - affected - 1) (fun _ -> Raw.const graph 0)
    in
    ignore (Raw.stabilize graph);
    Raw.reset_counts graph;
    Raw.set graph source 1;
    ignore (Raw.stabilize graph);
    let counts = Raw.counts graph in
    assert_int "half-graph value" (affected + 1) (Raw.value output);
    assert_int "half-graph claims" (affected + 1) counts.claims;
    assert_int "half-graph dependency edges" affected
      counts.dependency_edges;
    assert_int "half-graph propagation edges" affected
      counts.propagation_edges;
    assert_int "half-graph evaluations" affected counts.evaluations;
    assert_int "half-graph cutoffs" affected counts.cutoffs
  in
  List.iter check_static_economics [ 1_000; 10_000; 100_000 ];

  let check_reduction size =
    let graph = Raw.create () in
    let sources = Array.init size (fun _ -> Raw.var graph 0) in
    let level = ref (Array.map Raw.watch sources) in
    let combine_calls = ref 0 in
    while Array.length !level > 1 do
      let current = !level in
      level :=
        Array.init (Array.length current / 2) (fun index ->
            Raw.map2
              ~cutoff:(fun _ _ -> false)
              (fun left right ->
                incr combine_calls;
                left + right)
              current.(index * 2) current.((index * 2) + 1))
    done;
    assert_int "reduction construction calls" (size - 1)
      !combine_calls;
    let aggregate_cutoff_calls = ref 0 in
    let output =
      Raw.map
        ~cutoff:(fun _ candidate ->
          incr aggregate_cutoff_calls;
          candidate = 1)
        Fun.id (!level).(0)
    in
    let _demand = Raw.demand output in
    ignore (Raw.stabilize graph);
    Raw.reset_counts graph;
    combine_calls := 0;
    aggregate_cutoff_calls := 0;
    Raw.set graph sources.(0) 1;
    ignore (Raw.stabilize graph);
    let depth = int_of_float (Float.log2 (float_of_int size)) in
    let counts = Raw.counts graph in
    assert_int "reduction suppressed value" 0 (Raw.value output);
    assert_int "changed-leaf combination calls" depth !combine_calls;
    assert_int "aggregate cutoff calls" 1 !aggregate_cutoff_calls;
    assert_int "reduction claims" (depth + 2) counts.claims;
    assert_int "reduction dependency edges" ((depth * 2) + 1)
      counts.dependency_edges;
    assert_int "reduction propagation edges" (depth + 1)
      counts.propagation_edges;
    assert_int "reduction evaluations" (depth + 1) counts.evaluations;
    assert_int "reduction cutoff checks" (depth + 1) counts.cutoffs;
    combine_calls := 0;
    aggregate_cutoff_calls := 0;
    Raw.set graph sources.(0) 2;
    ignore (Raw.stabilize graph);
    assert_int "reduction published value" 2 (Raw.value output);
    assert_int "next changed-leaf combination calls" depth !combine_calls;
    assert_int "next aggregate cutoff calls" 1 !aggregate_cutoff_calls
  in
  let size = ref 1 in
  while !size <= 131_072 do
    check_reduction !size;
    size := !size * 2
  done;
  Printf.printf "semantic checks passed\n%!"

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
    Printf.printf "%s,%d,%d,%.6f,%.6f\n%!"
      workload.name operations sample wall_ns allocated_words
  done

let candidates =
  [
    "plan.changed.depth_1", (fun () -> make_plan_changed 1);
    "plan.changed.depth_10", (fun () -> make_plan_changed 10);
    "plan.changed.depth_100", (fun () -> make_plan_changed 100);
    "plan.cutoff.depth_10", (fun () -> make_plan_cutoff 10);
    "raw.changed.depth_1", (fun () -> make_raw_changed 1);
    "raw.changed.depth_10", (fun () -> make_raw_changed 10);
    "raw.changed.depth_100", (fun () -> make_raw_changed 100);
    "raw.cutoff.depth_10", (fun () -> make_raw_cutoff 10);
    "raw.fan_in.diamond", make_raw_fan_in;
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
  if check then check_semantics ()
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
