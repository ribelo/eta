type counters = {
  actions : int;
  transitions : int;
  driver_cycles : int;
  observations : int;
  projections : int;
  child_visits : int;
  changed_rows : int;
}

let zero =
  {
    actions = 0;
    transitions = 0;
    driver_cycles = 0;
    observations = 0;
    projections = 0;
    child_visits = 0;
    changed_rows = 0;
  }

let add left right =
  {
    actions = left.actions + right.actions;
    transitions = left.transitions + right.transitions;
    driver_cycles = left.driver_cycles + right.driver_cycles;
    observations = left.observations + right.observations;
    projections = left.projections + right.projections;
    child_visits = left.child_visits + right.child_visits;
    changed_rows = left.changed_rows + right.changed_rows;
  }

let sub left right =
  {
    actions = left.actions - right.actions;
    transitions = left.transitions - right.transitions;
    driver_cycles = left.driver_cycles - right.driver_cycles;
    observations = left.observations - right.observations;
    projections = left.projections - right.projections;
    child_visits = left.child_visits - right.child_visits;
    changed_rows = left.changed_rows - right.changed_rows;
  }

let scale count value =
  {
    actions = count * value.actions;
    transitions = count * value.transitions;
    driver_cycles = count * value.driver_cycles;
    observations = count * value.observations;
    projections = count * value.projections;
    child_visits = count * value.child_visits;
    changed_rows = count * value.changed_rows;
  }

let equal left right =
  left.actions = right.actions
  && left.transitions = right.transitions
  && left.driver_cycles = right.driver_cycles
  && left.observations = right.observations
  && left.projections = right.projections
  && left.child_visits = right.child_visits
  && left.changed_rows = right.changed_rows

let counters_to_string value =
  Printf.sprintf
    "{actions=%d; transitions=%d; driver_cycles=%d; observations=%d; \
     projections=%d; child_visits=%d; changed_rows=%d}"
    value.actions value.transitions value.driver_cycles value.observations
    value.projections value.child_visits value.changed_rows

type instance = {
  expected_per_operation : counters;
  snapshot : unit -> counters;
  isolated_operations : bool;
  set_full_validation : bool -> unit;
  prepare_batch : unit -> unit;
  run_batch : operations:int -> unit;
  finish_batch : unit -> unit;
  teardown : unit -> unit;
}

type workload = {
  name : string;
  create : unit -> instance;
}

let workload name create = { name; create }

type options = {
  filter : string option;
  operations : int option;
  samples : int;
  warmups : int;
  target_ms : float;
  verify : bool;
  list_only : bool;
  calibrate : bool;
}

let parse_args () =
  let filter = ref None in
  let operations = ref None in
  let samples = ref 1 in
  let warmups = ref 5 in
  let target_ms = ref 50. in
  let verify = ref false in
  let list_only = ref false in
  let calibrate = ref false in
  let rec loop = function
    | [] -> ()
    | "--filter" :: value :: rest ->
        filter := Some value;
        loop rest
    | "--operations" :: value :: rest ->
        operations := Some (int_of_string value);
        loop rest
    | "--samples" :: value :: rest ->
        samples := int_of_string value;
        loop rest
    | "--warmups" :: value :: rest ->
        warmups := int_of_string value;
        loop rest
    | "--target-ms" :: value :: rest ->
        target_ms := float_of_string value;
        loop rest
    | "--verify" :: rest ->
        verify := true;
        loop rest
    | "--list" :: rest ->
        list_only := true;
        loop rest
    | "--calibrate" :: rest ->
        calibrate := true;
        loop rest
    | argument :: _ -> invalid_arg ("unknown benchmark argument: " ^ argument)
  in
  loop (List.tl (Array.to_list Sys.argv));
  if !samples < 1 then invalid_arg "--samples must be positive";
  if !warmups < 0 then invalid_arg "--warmups must not be negative";
  Option.iter
    (fun value ->
      if value < 1 then invalid_arg "--operations must be positive")
    !operations;
  {
    filter = !filter;
    operations = !operations;
    samples = !samples;
    warmups = !warmups;
    target_ms = !target_ms;
    verify = !verify;
    list_only = !list_only;
    calibrate = !calibrate;
  }

let selected options workload =
  match options.filter with
  | None -> true
  | Some filter ->
      let regexp = Str.regexp filter in
      (try
         ignore (Str.search_forward regexp workload.name 0);
         true
       with Not_found -> false)

let minor_heap_words = 256 * 1024
let space_overhead = 120
let heap_prime_words = 8 * 1024 * 1024

let prime_runtime () =
  Gc.set { (Gc.get ()) with minor_heap_size = minor_heap_words; space_overhead };
  let block = heap_prime_words / 8 in
  let sink = ref [] in
  for _ = 1 to 8 do
    sink := Array.make block 0 :: !sink
  done;
  ignore (Sys.opaque_identity !sink);
  sink := [];
  Gc.full_major ()

type sample = {
  wall_ns : float;
  allocated_words : float;
  minor_words : float;
  promoted_words : float;
  major_words : float;
  minor_collections : int;
  major_collections : int;
  compactions : int;
  counters : counters;
}

let run_checked ?(full_validation = false) instance operations =
  instance.set_full_validation full_validation;
  Fun.protect
    ~finally:(fun () -> instance.set_full_validation false)
    (fun () ->
      let before = instance.snapshot () in
      if instance.isolated_operations then
        for _ = 1 to operations do
          instance.prepare_batch ();
          Fun.protect
            ~finally:instance.finish_batch
            (fun () -> instance.run_batch ~operations:1)
        done
      else (
        instance.prepare_batch ();
        Fun.protect
          ~finally:instance.finish_batch
          (fun () -> instance.run_batch ~operations));
      let observed = sub (instance.snapshot ()) before in
      let expected = scale operations instance.expected_per_operation in
      if not (equal observed expected) then
        failwith
          (Printf.sprintf "semantic counters differ: expected %s, observed %s"
             (counters_to_string expected) (counters_to_string observed));
      observed)

let measure instance operations =
  Gc.compact ();
  let semantic_before = instance.snapshot () in
  let measure_region operations =
    let gc_before = Gc.quick_stat () in
    let before_minor, before_promoted, before_major = Gc.counters () in
    let started = Mtime_clock.counter () in
    instance.run_batch ~operations;
    let wall_ns = Mtime.Span.to_float_ns (Mtime_clock.count started) in
    let after_minor, after_promoted, after_major = Gc.counters () in
    let gc_after = Gc.quick_stat () in
    let minor_words = after_minor -. before_minor in
    let promoted_words = after_promoted -. before_promoted in
    let major_words = after_major -. before_major in
    {
      wall_ns;
      allocated_words = minor_words +. major_words -. promoted_words;
      minor_words;
      promoted_words;
      major_words;
      minor_collections =
        gc_after.minor_collections - gc_before.minor_collections;
      major_collections =
        gc_after.major_collections - gc_before.major_collections;
      compactions = gc_after.compactions - gc_before.compactions;
      counters = zero;
    }
  in
  let add_sample left right =
    {
      wall_ns = left.wall_ns +. right.wall_ns;
      allocated_words = left.allocated_words +. right.allocated_words;
      minor_words = left.minor_words +. right.minor_words;
      promoted_words = left.promoted_words +. right.promoted_words;
      major_words = left.major_words +. right.major_words;
      minor_collections = left.minor_collections + right.minor_collections;
      major_collections = left.major_collections + right.major_collections;
      compactions = left.compactions + right.compactions;
      counters = zero;
    }
  in
  let measured =
    if instance.isolated_operations then (
      let total =
        ref
          {
            wall_ns = 0.;
            allocated_words = 0.;
            minor_words = 0.;
            promoted_words = 0.;
            major_words = 0.;
            minor_collections = 0;
            major_collections = 0;
            compactions = 0;
            counters = zero;
          }
      in
      for _ = 1 to operations do
        instance.prepare_batch ();
        let sample =
          Fun.protect
            ~finally:instance.finish_batch
            (fun () -> measure_region 1)
        in
        total := add_sample !total sample
      done;
      !total)
    else (
      instance.prepare_batch ();
      Fun.protect
        ~finally:instance.finish_batch
        (fun () -> measure_region operations))
  in
  let counters = sub (instance.snapshot ()) semantic_before in
  let expected = scale operations instance.expected_per_operation in
  if not (equal counters expected) then
    failwith
      (Printf.sprintf "semantic counters differ: expected %s, observed %s"
         (counters_to_string expected) (counters_to_string counters));
  { measured with counters }

let calibrate instance target_ms =
  let target_ns = target_ms *. 1_000_000. in
  let rec loop operations =
    let sample = measure instance operations in
    if sample.wall_ns >= target_ns || operations >= 1 lsl 28 then operations
    else
      let ratio = target_ns /. max 1. sample.wall_ns in
      let factor = max 2 (min 16 (int_of_float (ceil ratio))) in
      loop (operations * factor)
  in
  loop 1

let json_string value =
  let buffer = Buffer.create (String.length value + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (function
      | '"' -> Buffer.add_string buffer "\\\""
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | character -> Buffer.add_char buffer character)
    value;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let emit_sample ~framework ~workload ~operations ~sample_index sample =
  let per_operation value = value /. float_of_int operations in
  Printf.printf
    "{\"kind\":\"sample\",\"framework\":%s,\"workload\":%s,\
     \"compiler\":%s,\"operations\":%d,\"sample\":%d,\
     \"wall_ns_per_op\":%.6f,\"allocated_words_per_op\":%.6f,\
     \"minor_words_per_op\":%.6f,\"promoted_words_per_op\":%.6f,\
     \"major_words_per_op\":%.6f,\"minor_collections_per_op\":%.9f,\
     \"major_collections_per_op\":%.9f,\"compactions_per_op\":%.9f,\
     \"counters\":{\
     \"actions\":%d,\"transitions\":%d,\"driver_cycles\":%d,\
     \"observations\":%d,\"projections\":%d,\"child_visits\":%d,\
     \"changed_rows\":%d}}\n%!"
    (json_string framework) (json_string workload)
    (json_string Sys.ocaml_version) operations sample_index
    (per_operation sample.wall_ns)
    (per_operation sample.allocated_words)
    (per_operation sample.minor_words)
    (per_operation sample.promoted_words)
    (per_operation sample.major_words)
    (per_operation (float_of_int sample.minor_collections))
    (per_operation (float_of_int sample.major_collections))
    (per_operation (float_of_int sample.compactions))
    sample.counters.actions sample.counters.transitions
    sample.counters.driver_cycles sample.counters.observations
    sample.counters.projections sample.counters.child_visits
    sample.counters.changed_rows

let emit_calibration ~framework ~workload operations =
  Printf.printf
    "{\"kind\":\"calibration\",\"framework\":%s,\"workload\":%s,\
     \"compiler\":%s,\"operations\":%d}\n%!"
    (json_string framework) (json_string workload)
    (json_string Sys.ocaml_version) operations

let run_one ~framework options workload =
  let instance = workload.create () in
  Fun.protect
    ~finally:instance.teardown
    (fun () ->
      if options.verify then (
        let operations = Option.value ~default:4 options.operations in
        ignore (run_checked ~full_validation:true instance operations);
        Printf.printf
          "{\"kind\":\"verification\",\"framework\":%s,\"workload\":%s,\
           \"status\":\"ok\"}\n%!"
          (json_string framework) (json_string workload.name))
      else if options.calibrate then
        calibrate instance options.target_ms
        |> emit_calibration ~framework ~workload:workload.name
      else
        let operations =
          match options.operations with
          | Some operations -> operations
          | None -> invalid_arg "measurement requires --operations"
        in
        for _ = 1 to options.warmups do
          ignore (run_checked instance operations)
        done;
        for sample_index = 0 to options.samples - 1 do
          measure instance operations
          |> emit_sample ~framework ~workload:workload.name ~operations
               ~sample_index
        done)

let main ~framework workloads =
  let options = parse_args () in
  if options.list_only then
    List.iter (fun workload -> print_endline workload.name) workloads
  else (
    prime_runtime ();
    let selected = List.filter (selected options) workloads in
    if selected = [] then invalid_arg "benchmark filter selected no workloads";
    List.iter (run_one ~framework options) selected)
