type measurement = {
  name : string;
  mean_ns : float;
  stddev_ns : float;
  median_ns : float;
  p95_ns : float;
  allocated_words_per_op : float;
}

let sink = ref 0

let percentile sorted fraction =
  let n = Array.length sorted in
  sorted.(min (n - 1) (int_of_float (ceil ((float n *. fraction) -. 1.))))

let mean values =
  Array.fold_left ( +. ) 0. values /. float_of_int (Array.length values)

let stddev values mean =
  if Array.length values < 2 then 0.
  else
    Array.fold_left
      (fun sum value ->
        let difference = value -. mean in
        sum +. (difference *. difference))
      0. values
    /. float_of_int (Array.length values - 1)
    |> sqrt

let elapsed run operations =
  let started = Unix.gettimeofday () in
  run operations;
  Unix.gettimeofday () -. started

let rec calibrate ~minimum_seconds run operations =
  if minimum_seconds = 0. then operations
  else
    let seconds = elapsed run operations in
    if seconds >= minimum_seconds then operations
    else calibrate ~minimum_seconds run (operations * 2)

let measure ~samples ~warmups ~minimum_seconds ~operations ~name run =
  let operations = calibrate ~minimum_seconds run operations in
  for _ = 1 to warmups do
    run operations
  done;
  let times = Array.make samples 0. in
  let allocations = Array.make samples 0. in
  for sample = 0 to samples - 1 do
    Gc.compact ();
    let before_minor, before_promoted, before_major = Gc.counters () in
    let started = Unix.gettimeofday () in
    run operations;
    let stopped = Unix.gettimeofday () in
    let after_minor, after_promoted, after_major = Gc.counters () in
    times.(sample) <- ((stopped -. started) *. 1e9) /. float operations;
    allocations.(sample) <-
      (after_minor -. before_minor +. after_major -. before_major
     -. (after_promoted -. before_promoted))
      /. float operations
  done;
  let mean_ns = mean times in
  let stddev_ns = stddev times mean_ns in
  Array.sort Float.compare times;
  Array.sort Float.compare allocations;
  {
    name;
    mean_ns;
    stddev_ns;
    median_ns = percentile times 0.5;
    p95_ns = percentile times 0.95;
    allocated_words_per_op = percentile allocations 0.5;
  }

let action operations =
  let model = ref 0 in
  for _ = 1 to operations do
    incr model;
    sink := !sink lxor !model
  done

let unchanged operations =
  let recomputations = ref 0 in
  let dirty = false in
  for _ = 1 to operations do
    if dirty then incr recomputations;
    sink := !sink lxor !recomputations
  done;
  assert (!recomputations = 0)

let changed_child operations =
  let children = Array.make 100_000 0 in
  let child_visits = ref 0 in
  for operation = 1 to operations do
    let index = operation mod Array.length children in
    children.(index) <- operation;
    incr child_visits;
    sink := !sink lxor children.(index)
  done;
  assert (!child_visits = operations)

let delivery_reconciliation operations =
  let previous = ref 0 in
  let deliveries = ref 0 in
  let mutations = ref 0 in
  for output = 1 to operations do
    incr deliveries;
    if output <> !previous then incr mutations;
    previous := output
  done;
  assert (!deliveries = operations);
  assert (!mutations = operations);
  sink := !sink lxor !previous

let lifecycle_overlap operations =
  let cleanup_requested = ref 0 in
  let new_work_started = ref 0 in
  for _ = 1 to operations do
    incr cleanup_requested;
    (* New work starts after the request, without waiting for cleanup. *)
    incr new_work_started
  done;
  assert (!cleanup_requested = operations);
  assert (!new_work_started = operations);
  sink := !sink lxor !new_work_started

let identity_driver operations =
  let wire_allocations = ref 0 in
  for value = 1 to operations do
    sink := !sink lxor value
  done;
  assert (!wire_allocations = 0)

let serialized_driver operations =
  let registry = Hashtbl.create 64 in
  for value = 1 to operations do
    let handle = value land 63 in
    Hashtbl.replace registry handle value;
    let encoded = string_of_int value in
    sink := !sink lxor int_of_string encoded
  done;
  assert (Hashtbl.length registry <= 64)

let telemetry_disabled operations =
  let enabled = false in
  let points = ref 0 in
  for value = 1 to operations do
    if enabled then incr points;
    sink := !sink lxor value
  done;
  assert (!points = 0)

let bounded_state operations =
  let ingress_capacity = 1_024 in
  let request_capacity = 256 in
  let live_exports = 10_000 in
  let ingress = Queue.create () in
  let requests = Hashtbl.create request_capacity in
  let handles = Hashtbl.create live_exports in
  for value = 1 to operations do
    if Queue.length ingress < ingress_capacity then Queue.push value ingress;
    if Hashtbl.length requests < request_capacity then
      Hashtbl.replace requests value ();
    Hashtbl.replace handles (value mod live_exports) ();
    if value land 1 = 0 && not (Queue.is_empty ingress) then
      ignore (Queue.pop ingress : int);
    if value > request_capacity then Hashtbl.remove requests (value - request_capacity)
  done;
  assert (Queue.length ingress <= ingress_capacity);
  assert (Hashtbl.length requests <= request_capacity);
  assert (Hashtbl.length handles <= live_exports);
  sink := !sink lxor Hashtbl.length handles

let emit item =
  Printf.printf
    "%s mean_ns/op=%.2f stddev_ns/op=%.2f median_ns/op=%.2f p95_ns/op=%.2f allocated_words/op=%.3f\n"
    item.name item.mean_ns item.stddev_ns item.median_ns item.p95_ns
    item.allocated_words_per_op

let () =
  let quick = ref false in
  let samples = ref 31 in
  Arg.parse
    [
      "--quick", Arg.Set quick, "use three samples";
      "--samples", Arg.Set_int samples, "number of samples";
    ]
    (fun value -> raise (Arg.Bad ("unexpected argument " ^ value)))
    "eta-crux-performance-gates-prototype";
  if !quick then samples := 3;
  if !samples < 3 then raise (Arg.Bad "--samples must be at least 3");
  let operations = if !quick then 1_000 else 100_000 in
  let warmups = if !quick then 0 else 5 in
  let minimum_seconds = if !quick then 0. else 0.05 in
  [
    "action.complete_advancement", action;
    "incremental.unchanged", unchanged;
    "assoc.changed_child.100k", changed_child;
    "adapter.delivery_reconciliation", delivery_reconciliation;
    "lifecycle.overlapping_cleanup", lifecycle_overlap;
    "driver.identity", identity_driver;
    "driver.serialized", serialized_driver;
    "telemetry.disabled", telemetry_disabled;
    "capacity.bounded_state", bounded_state;
  ]
  |> List.map (fun (name, run) ->
         measure ~samples:!samples ~warmups ~minimum_seconds ~operations ~name
           run)
  |> List.iter emit
