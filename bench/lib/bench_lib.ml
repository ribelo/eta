type opts = {
  quick : bool;
  filter_raw : string option;
  filter : Str.regexp option;
  samples : int;
}

type workload = {
  name : string;
  run : unit -> unit;
  samples : int option;
}

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
  let default_samples = if !quick then 1 else 5 in
  {
    quick = !quick;
    filter_raw = !filter_raw;
    filter = !filter;
    samples = Option.value !samples ~default:default_samples;
  }

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

let emit_measurement ~name ~metric ~unit samples =
  let samples_json = samples |> List.map json_float |> String.concat "," in
  Printf.printf
    "{\"name\":%s,\"metric\":%s,\"unit\":%s,\"samples\":[%s],\"mean\":%s,\"stddev\":%s,\"min\":%s,\"max\":%s}\n%!"
    (json_string name) (json_string metric) (json_string unit) samples_json
    (json_float (mean samples)) (json_float (stddev samples))
    (json_float (min_float samples)) (json_float (max_float samples))

let measure_once f =
  Gc.compact ();
  let before = Gc.quick_stat () in
  let start = Unix.gettimeofday () in
  f ();
  let stop = Unix.gettimeofday () in
  let after = Gc.quick_stat () in
  let wall_ns = (stop -. start) *. 1_000_000_000. in
  let minor_words = after.minor_words -. before.minor_words in
  let major_words = after.major_words -. before.major_words in
  (wall_ns, minor_words, major_words)

let run_workload opts workload =
  if should_run opts workload.name then
    let samples = Option.value workload.samples ~default:opts.samples in
    let rec collect i walls minors majors =
      if i = 0 then (List.rev walls, List.rev minors, List.rev majors)
      else
        let wall, minor, major = measure_once workload.run in
        collect (i - 1) (wall :: walls) (minor :: minors) (major :: majors)
    in
    let walls, minors, majors = collect samples [] [] [] in
    emit_measurement ~name:workload.name ~metric:"wall_ns" ~unit:"ns" walls;
    emit_measurement ~name:workload.name ~metric:"minor_words" ~unit:"words" minors;
    emit_measurement ~name:workload.name ~metric:"major_words" ~unit:"words" majors

let run opts workloads = List.iter (run_workload opts) workloads
