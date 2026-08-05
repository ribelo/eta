type opts = {
  quick : bool;
  filter_raw : string option;
  filter : Str.regexp option;
  samples : int;
}

(** Invoke [f] exactly [n] times when [n > 0]; never invoke it for [n <= 0].
    The loop itself allocates nothing. *)
let repeat n f =
  for _ = 1 to n do
    f ()
  done

(** [ops] is the number of measured operations performed by one [run] call. It
    is the normalization basis for the derived [*_per_op] rows, and it is
    recorded in the emitted JSON so a reader never has to guess it. Use [1] for
    a workload whose [run] is itself the unit of interest. *)
type workload = {
  name : string;
  run : unit -> unit;
  samples : int option;
  ops : int;
}

let workload ?samples ?(ops = 1) name run =
  if ops < 1 then invalid_arg "Bench_lib.workload: ops must be positive";
  { name; run; samples; ops }

let parse_args () =
  let quick = ref false in
  let filter_raw = ref None in
  let filter = ref None in
  let samples = ref None in
  let rec loop = function
    | [] -> ()
    | "--quick" :: rest ->
        quick := true;
        loop rest
    | "--filter" :: value :: rest ->
        filter_raw := Some value;
        filter := Some (Str.regexp value);
        loop rest
    | "--samples" :: value :: rest ->
        samples := Some (int_of_string value);
        loop rest
    | arg :: _ -> invalid_arg ("unknown bench argument: " ^ arg)
  in
  loop (List.tl (Array.to_list Sys.argv));
  (* Never 1: the first timed sample of a workload is discarded as warmup, and
     a single surviving sample carries no dispersion at all. *)
  let default_samples = if !quick then 3 else 7 in
  {
    quick = !quick;
    filter_raw = !filter_raw;
    filter = !filter;
    samples = Option.value !samples ~default:default_samples;
  }

let sorted samples = List.sort compare samples

let median samples =
  match sorted samples with
  | [] -> 0.
  | xs ->
      let n = List.length xs in
      let arr = Array.of_list xs in
      if n mod 2 = 1 then arr.(n / 2)
      else (arr.((n / 2) - 1) +. arr.(n / 2)) /. 2.

(** Divide a per-[run] measurement by the operations one [run] performs. *)
let per_op ~ops value =
  if ops < 1 then invalid_arg "Bench_lib.per_op: ops must be positive"
  else value /. float_of_int ops

let contains literal name =
  try
    ignore (Str.search_forward (Str.regexp_string literal) name 0);
    true
  with Not_found -> false

let should_run opts name =
  match (opts.filter_raw, opts.filter) with
  | None, _ -> true
  | Some raw, Some re -> (
      try
        ignore (Str.search_forward re name 0);
        true
      with Not_found ->
        raw |> String.split_on_char '|' |> List.exists (fun part -> contains part name))
  | Some raw, None -> contains raw name

let mean samples =
  match samples with
  | [] -> 0.
  | xs -> List.fold_left ( +. ) 0. xs /. float_of_int (List.length xs)

let stddev samples =
  match samples with
  | [] | [ _ ] -> 0.
  | xs ->
      let m = mean xs in
      let sum =
        List.fold_left
          (fun acc x ->
            let d = x -. m in
            acc +. (d *. d))
          0. xs
      in
      sqrt (sum /. float_of_int (List.length xs - 1))

let min_float = function
  | [] -> 0.
  | x :: xs -> List.fold_left min x xs

let max_float = function
  | [] -> 0.
  | x :: xs -> List.fold_left max x xs

let json_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (function
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\b' -> Buffer.add_string b "\\b"
      | '\012' -> Buffer.add_string b "\\f"
      | '\n' -> Buffer.add_string b "\\n"
      | '\r' -> Buffer.add_string b "\\r"
      | '\t' -> Buffer.add_string b "\\t"
      | c when Char.code c < 0x20 ->
          Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let json_float n =
  if classify_float n = FP_nan || classify_float n = FP_infinite then "0"
  else Printf.sprintf "%.6f" n

let emit_measurement ~name ~metric ~unit ~ops samples =
  let samples_json = samples |> List.map json_float |> String.concat "," in
  Printf.printf
    "{\"name\":%s,\"metric\":%s,\"unit\":%s,\"ops\":%d,\"samples\":[%s],\"mean\":%s,\"median\":%s,\"stddev\":%s,\"min\":%s,\"max\":%s}\n%!"
    (json_string name) (json_string metric) (json_string unit) ops samples_json
    (json_float (mean samples)) (json_float (median samples))
    (json_float (stddev samples))
    (json_float (min_float samples)) (json_float (max_float samples))

let measure_once f =
  (* [full_major] settles pending collector work so the sample's GC counters and
     wall time belong to the sample. It deliberately does not compact: releasing
     the heap to the OS before every sample made a row's cost depend on the
     heap history of whichever rows ran before it, which broke filtered runs. *)
  Gc.full_major ();
  let before_minor, before_promoted, before_major = Gc.counters () in
  (* Monotonic. [Unix.gettimeofday] returns absolute epoch seconds in a double,
     which quantizes to ~238 ns and is subject to clock steps. *)
  let start = Mtime_clock.counter () in
  f ();
  let wall_ns = Mtime.Span.to_float_ns (Mtime_clock.count start) in
  let after_minor, after_promoted, after_major = Gc.counters () in
  let minor_words = after_minor -. before_minor in
  let promoted_words = after_promoted -. before_promoted in
  let major_words = after_major -. before_major in
  let allocated_words = minor_words +. major_words -. promoted_words in
  (wall_ns, allocated_words, minor_words, promoted_words, major_words)

let run_workload opts workload =
  if should_run opts workload.name then
    let samples = Option.value workload.samples ~default:opts.samples in
    (* Warmup. The first invocation of a workload pays one-time costs - code
       paging, lazy initialisation, heap growth to the workload's high-water
       mark - that a steady-state consumer does not pay per operation. It is
       measured and then dropped rather than skipped, so that its GC work is
       accounted for before the reported samples begin. *)
    ignore (measure_once workload.run);
    let rec collect i walls allocated minors promoteds majors =
      if i = 0 then
        ( List.rev walls,
          List.rev allocated,
          List.rev minors,
          List.rev promoteds,
          List.rev majors )
      else
        let wall, alloc, minor, promoted, major = measure_once workload.run in
        collect (i - 1) (wall :: walls) (alloc :: allocated) (minor :: minors)
          (promoted :: promoteds) (major :: majors)
    in
    let walls, allocated, minors, promoted, majors =
      collect samples [] [] [] [] []
    in
    let ops = workload.ops in
    let emit metric unit samples =
      emit_measurement ~name:workload.name ~metric ~unit ~ops samples
    in
    emit "wall_ns" "ns" walls;
    emit "allocated_words" "words" allocated;
    emit "minor_words" "words" minors;
    emit "promoted_words" "words" promoted;
    emit "major_words" "words" majors;
    if ops > 1 then begin
      let normalize samples = List.map (per_op ~ops) samples in
      emit "wall_ns_per_op" "ns/op" (normalize walls);
      emit "allocated_words_per_op" "words/op" (normalize allocated)
    end

(* Benchmark runs must not depend on the ambient [OCAMLRUNPARAM], and a row's
   cost must not depend on how much earlier rows in the same process allocated.
   Major-heap pacing does depend on that history: the same 100k-node workload
   measured 2.4x faster after other large rows had already grown the heap than
   it did when selected alone with [--filter]. Pin the collector parameters and
   raise the major heap to a fixed working size before any workload runs, so a
   filtered run and a full run start every row from the same collector regime. *)
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
  (* [full_major] reclaims the primed words but, unlike [compact], leaves the
     pools with the runtime, which is exactly the state we want to pin. *)
  Gc.full_major ()

let run opts workloads =
  prime_runtime ();
  List.iter (run_workload opts) workloads
