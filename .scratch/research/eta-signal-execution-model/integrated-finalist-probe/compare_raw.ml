(* The raw runner deliberately depends on the finalist-owned synchronous
   benchmark adapter. It keeps Eta Effect and the final observer read outside
   the measured operation. *)

module Raw = Raw_benchmark

type workload = {
  name : string;
  run_batch : int -> unit;
  check : unit -> unit;
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
  Printf.printf "name,operations,sample,wall_ns,allocated_words\n%!";
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

let parse_args () =
  let rec loop only samples = function
    | [] -> only, samples
    | "--only" :: name :: rest -> loop (Some name) samples rest
    | "--samples" :: count :: rest ->
        loop only (int_of_string count) rest
    | argument :: _ -> invalid_arg ("unknown argument: " ^ argument)
  in
  loop None 9 (List.tl (Array.to_list Sys.argv))

let () =
  match parse_args () with
  | Some name, sample_count when sample_count > 0 ->
      let raw = Raw.create name in
      measure ~sample_count
        {
          name = Raw.name raw;
          run_batch = (fun operations -> Raw.run_batch raw operations);
          check = (fun () -> Raw.final_read_and_check raw);
        }
  | Some _, _ -> invalid_arg "--samples must be positive"
  | None, _ -> invalid_arg "exactly one raw workload is required: --only NAME"
