(* runtime_par — Par benchmark suite.

   Orchestrates all kernels under a single pool, validates correctness
   (parallel checksum must equal serial checksum), and emits METRIC
   lines for autoresearch.

   Boundary: this file and every kernel_*.ml beside it depend on
   [par] only.  The dune file is the gate — it does not list any
   internal modules.  If you find yourself wanting to reach into the
   scheduler from a benchmark, that is a sign the public API is
   missing something; add it to par.mli, do not bypass it. *)

(* ---------------------------------------------------------------------- *)
(* Kernel registry.                                                        *)
(* ---------------------------------------------------------------------- *)

module type KERNEL = sig
  val name : string
  val description : string
  val run_serial : quick:bool -> unit -> string
  val run_parallel : quick:bool -> Par.Pool.t -> string
end

let kernels : (module KERNEL) list =
  [
    (module Kernel_fib);
    (module Kernel_qsort);
    (module Kernel_map);
    (module Kernel_reduce);
    (module Kernel_pathological);
    (module Kernel_irregular);
    (module Kernel_matmul);
    (module Kernel_micro_join);
  ]

(* ---------------------------------------------------------------------- *)
(* Measurement helpers.                                                    *)
(* ---------------------------------------------------------------------- *)

let time f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  let t1 = Unix.gettimeofday () in
  (r, t1 -. t0)

let median ts =
  let sorted = List.sort compare ts in
  List.nth sorted (List.length sorted / 2)

let geomean xs =
  let n = List.length xs in
  if n = 0 then 0.0
  else
    let log_sum =
      List.fold_left (fun acc x -> acc +. log x) 0.0 xs
    in
    exp (log_sum /. float_of_int n)

(* Allocations during one parallel run.  [Gc.stat] sums across
   domains, so this captures workers' allocations too — but it walks
   the heap, which can cost milliseconds.  Run it AFTER timing. *)
let measure_minor_words pool kernel ~quick =
  let module K = (val kernel : KERNEL) in
  let before = (Gc.stat ()).minor_words in
  let _ = K.run_parallel ~quick pool in
  let after = (Gc.stat ()).minor_words in
  int_of_float (after -. before)

(* ---------------------------------------------------------------------- *)
(* Per-kernel benchmark.                                                   *)
(* ---------------------------------------------------------------------- *)

type result = {
  kernel : string;
  serial_ms : float;
  parallel_ms : float;       (* median across iters *)
  parallel_best_ms : float;  (* fastest across iters *)
  speedup : float;
  minor_words : int;
  ok : bool;
}

let run_kernel ~quick ~iters pool kernel =
  let module K = (val kernel : KERNEL) in
  (* 1. One warm-up serial run — primes caches and JIT, validates
     the parallel version against this checksum.  An earlier draft
     timed serial as a single run with no warm-up; that gave the
     parallel side an unfair cache advantage and inflated the
     reported speedup. *)
  let serial_checksum = K.run_serial ~quick () in
  (* 2. Timed serial runs — same iteration count as parallel so
     median-vs-median is honest. *)
  let serial_times =
    List.init iters (fun _ ->
      let r, t = time (fun () -> K.run_serial ~quick ()) in
      if r <> serial_checksum then
        Printf.printf "  ! %s: serial iteration mismatch %s != %s\n%!"
          K.name r serial_checksum;
      t)
  in
  let t_ser = median serial_times in
  (* 3. One warm-up parallel run, validates result, primes caches. *)
  let warm = K.run_parallel ~quick pool in
  let ok = (warm = serial_checksum) in
  if not ok then begin
    Printf.printf "  ! %s: parallel checksum %s != serial %s\n%!"
      K.name warm serial_checksum
  end;
  (* 4. Timed parallel runs. *)
  let times =
    List.init iters (fun _ ->
      let r, t = time (fun () -> K.run_parallel ~quick pool) in
      if r <> serial_checksum then
        Printf.printf "  ! %s: iteration mismatch %s != %s\n%!"
          K.name r serial_checksum;
      t)
  in
  let med = median times in
  let best = List.fold_left min infinity times in
  let minor = measure_minor_words pool kernel ~quick in
  {
    kernel = K.name;
    serial_ms = t_ser *. 1000.0;
    parallel_ms = med *. 1000.0;
    parallel_best_ms = best *. 1000.0;
    speedup = t_ser /. med;
    minor_words = minor;
    ok;
  }

(* ---------------------------------------------------------------------- *)
(* Reporting.                                                              *)
(* ---------------------------------------------------------------------- *)

let report_human results =
  Printf.printf "\n%-16s %10s %10s %10s %8s %14s %s\n"
    "kernel" "serial(ms)" "par(ms)" "best(ms)" "speedup" "minor_words" "ok";
  Printf.printf "%s\n" (String.make 80 '-');
  List.iter
    (fun r ->
      Printf.printf "%-16s %10.1f %10.1f %10.1f %8.2fx %14d %s\n" r.kernel
        r.serial_ms r.parallel_ms r.parallel_best_ms r.speedup r.minor_words
        (if r.ok then "✓" else "✗"))
    results

let report_metrics results =
  (* Per-kernel METRIC lines (secondaries). *)
  List.iter
    (fun r ->
      Printf.printf "METRIC TIME_%s_MS=%.1f\n" (String.uppercase_ascii r.kernel)
        r.parallel_ms;
      Printf.printf "METRIC SPEEDUP_%s=%.3f\n"
        (String.uppercase_ascii r.kernel)
        r.speedup;
      Printf.printf "METRIC MINOR_%s=%d\n" (String.uppercase_ascii r.kernel)
        r.minor_words)
    results;
  let total_par_ms =
    List.fold_left (fun acc r -> acc +. r.parallel_ms) 0.0 results
  in
  let total_minor =
    List.fold_left (fun acc r -> acc + r.minor_words) 0 results
  in
  let geomean_speedup =
    geomean (List.map (fun r -> r.speedup) results)
  in
  Printf.printf "METRIC TOTAL_PARALLEL_MS=%.1f\n" total_par_ms;
  Printf.printf "METRIC TOTAL_MINOR_WORDS=%d\n" total_minor;
  Printf.printf "METRIC GEOMEAN_SPEEDUP=%.3f\n" geomean_speedup;
  let all_ok = List.for_all (fun r -> r.ok) results in
  if all_ok then print_endline "PASS" else print_endline "FAIL"

(* ---------------------------------------------------------------------- *)
(* CLI.                                                                    *)
(* ---------------------------------------------------------------------- *)

let usage () =
  prerr_endline
    "Usage: runtime_par [--quick] [--iters N] [--workers N] [--kernel NAME]\n\n\
     With no args: runs the full suite, 5 iterations, 4 workers.\n\
     --quick reduces every workload to make iteration in autoresearch fast.\n\
     --kernel NAME runs just one kernel (still validates against serial).\n";
  exit 2

let () =
  let quick = ref false in
  let iters = ref 5 in
  let workers = ref 4 in
  let kernel_filter = ref None in
  let rec parse i =
    if i >= Array.length Sys.argv then ()
    else
      match Sys.argv.(i) with
      | "--quick" ->
          quick := true;
          parse (i + 1)
      | "--iters" ->
          iters := int_of_string Sys.argv.(i + 1);
          parse (i + 2)
      | "--workers" ->
          workers := int_of_string Sys.argv.(i + 1);
          parse (i + 2)
      | "--kernel" ->
          kernel_filter := Some Sys.argv.(i + 1);
          parse (i + 2)
      | "-h" | "--help" -> usage ()
      | s ->
          Printf.eprintf "unknown arg %S\n" s;
          usage ()
  in
  parse 1;
  let selected =
    match !kernel_filter with
    | None -> kernels
    | Some n ->
        List.filter
          (fun (module K : KERNEL) -> K.name = n)
          kernels
  in
  if selected = [] then begin
    prerr_endline "no kernel matched";
    exit 2
  end;
  Printf.printf "par bench suite — workers=%d iters=%d quick=%b kernels=%d\n%!"
    !workers !iters !quick (List.length selected);
  Par.Pool.with_pool ~n_workers:!workers (fun pool ->
    let results = List.map (run_kernel ~quick:!quick ~iters:!iters pool) selected in
    report_human results;
    print_endline "";
    report_metrics results)
