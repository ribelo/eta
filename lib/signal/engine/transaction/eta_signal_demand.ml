type counters = {
  mutable enabled : bool;
  mutable reference_operations : int;
  mutable zero_boundaries : int;
  mutable dependency_edge_visits : int;
  mutable timer_desired_state_transitions : int;
}

type counter_snapshot = {
  reference_operations : int;
  zero_boundaries : int;
  dependency_edge_visits : int;
  timer_desired_state_transitions : int;
}

let create_counters () =
  {
    enabled = false;
    reference_operations = 0;
    zero_boundaries = 0;
    dependency_edge_visits = 0;
    timer_desired_state_transitions = 0;
  }

let reset_counters counters =
  counters.enabled <- true;
  counters.reference_operations <- 0;
  counters.zero_boundaries <- 0;
  counters.dependency_edge_visits <- 0;
  counters.timer_desired_state_transitions <- 0

let disable_counters counters = counters.enabled <- false

let counter_snapshot (counters : counters) =
  {
    reference_operations = counters.reference_operations;
    zero_boundaries = counters.zero_boundaries;
    dependency_edge_visits = counters.dependency_edge_visits;
    timer_desired_state_transitions =
      counters.timer_desired_state_transitions;
  }

let succ value = if value = max_int then max_int else value + 1

let note_reference_operation counters =
  if counters.enabled then
    counters.reference_operations <- succ counters.reference_operations

let note_zero_boundary counters =
  if counters.enabled then
    counters.zero_boundaries <- succ counters.zero_boundaries

let note_dependency_edge_visit counters =
  if counters.enabled then
    counters.dependency_edge_visits <- succ counters.dependency_edge_visits

let note_timer_desired_state_transition counters =
  if counters.enabled then
    counters.timer_desired_state_transitions <-
      succ counters.timer_desired_state_transitions

type ('node, 'edge) ops = {
  demand : 'node -> int;
  set_demand : 'node -> int -> unit;
  iter_dependencies : 'node -> ('edge -> unit) -> unit;
  dependency : 'edge -> 'node;
  on_boundary : 'node -> necessary:bool -> unit;
}

let ops ~demand ~set_demand ~iter_dependencies ~dependency ~on_boundary =
  { demand; set_demand; iter_dependencies; dependency; on_boundary }

let validate_delta delta =
  if delta <> 1 && delta <> -1 then
    invalid_arg "Eta_signal_demand.adjust: delta must be one or minus one"

let adjust_many counters ops roots delta =
  validate_delta delta;
  let exception Count_error of [ `Overflow | `Underflow ] in
  let changes = ref [] in
  let boundaries = ref [] in
  let rec loop = function
    | [] -> ()
    | (node, delta) :: rest ->
        note_reference_operation counters;
        let previous = ops.demand node in
        let next =
          if delta = 1 then (
            if previous = max_int then raise (Count_error `Overflow);
            previous + 1)
          else (
            if previous = 0 then raise (Count_error `Underflow);
            previous - 1)
        in
        ops.set_demand node next;
        changes := (node, previous) :: !changes;
        let crossed = previous = 0 || next = 0 in
        if crossed then (
          note_zero_boundary counters;
          boundaries := (node, next > 0) :: !boundaries;
          let pending = ref rest in
          ops.iter_dependencies node (fun edge ->
              note_dependency_edge_visit counters;
              pending := (ops.dependency edge, delta) :: !pending);
          loop !pending)
        else loop rest
  in
  try
    List.iter (fun root -> loop [ root, delta ]) roots;
    List.iter
      (fun (node, necessary) -> ops.on_boundary node ~necessary)
      (List.rev !boundaries);
    Ok ()
  with Count_error error ->
    List.iter
      (fun (node, previous) -> ops.set_demand node previous)
      !changes;
    Error error

let adjust counters ops root delta = adjust_many counters ops [ root ] delta

let check ops root delta =
  validate_delta delta;
  let exception Count_error of [ `Overflow | `Underflow ] in
  let rec loop = function
    | [] -> ()
    | (node, delta) :: rest ->
        let previous = ops.demand node in
        let next =
          if delta = 1 then (
            if previous = max_int then raise (Count_error `Overflow);
            previous + 1)
          else (
            if previous = 0 then raise (Count_error `Underflow);
            previous - 1)
        in
        let crossed = previous = 0 || next = 0 in
        if crossed then
          let pending = ref rest in
          ops.iter_dependencies node (fun edge ->
              pending := (ops.dependency edge, delta) :: !pending);
          loop !pending
        else loop rest
  in
  try
    loop [ root, delta ];
    Ok ()
  with Count_error error -> Error error
