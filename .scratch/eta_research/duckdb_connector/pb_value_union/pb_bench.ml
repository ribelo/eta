(* P-B benchmark: function-call boundary cost of widening Value.t

   Tests: function returning Value.t (no_inline), called 10M times,
   pattern match on result. Compares 7-case vs 15-case.
*)

let num_iterations = 10_000_000

let time f =
  let t0 = Unix.gettimeofday () in
  let result = f () in
  let t1 = Unix.gettimeofday () in
  (result, t1 -. t0)

let run_v7 () =
  let sum = ref 0 in
  for i = 1 to num_iterations do
    let v = Value_v7.get_value i in
    sum := !sum + Value_v7.extract_int v
  done;
  !sum

let run_v15 () =
  let sum = ref 0 in
  for i = 1 to num_iterations do
    let v = Value_v15.get_value i in
    sum := !sum + Value_v15.extract_int v
  done;
  !sum

let () =
  Printf.printf "=== P-B Function-Boundary Benchmark ===\n";
  Printf.printf "Iterations: %d\n\n" num_iterations;

  (* Warmup *)
  let _ = run_v7 () in
  let _ = run_v15 () in

  (* Run V7 *)
  Gc.full_major ();
  let gc_before = Gc.quick_stat () in
  let (sum7, t7) = time run_v7 in
  let gc_after = Gc.quick_stat () in
  let minor7 = gc_after.minor_words -. gc_before.minor_words in
  let major7 = gc_after.major_words -. gc_before.major_words in

  Printf.printf "V7 (7 constructors):\n";
  Printf.printf "  sum: %d\n" sum7;
  Printf.printf "  time: %.3f s\n" t7;
  Printf.printf "  minor_words: %.0f\n" minor7;
  Printf.printf "  major_words: %.0f\n" major7;
  Printf.printf "  per_iter: %.2f words\n\n" (minor7 /. float_of_int num_iterations);

  (* Run V15 *)
  Gc.full_major ();
  let gc_before = Gc.quick_stat () in
  let (sum15, t15) = time run_v15 in
  let gc_after = Gc.quick_stat () in
  let minor15 = gc_after.minor_words -. gc_before.minor_words in
  let major15 = gc_after.major_words -. gc_before.major_words in

  Printf.printf "V15 (15 constructors):\n";
  Printf.printf "  sum: %d\n" sum15;
  Printf.printf "  time: %.3f s\n" t15;
  Printf.printf "  minor_words: %.0f\n" minor15;
  Printf.printf "  major_words: %.0f\n" major15;
  Printf.printf "  per_iter: %.2f words\n\n" (minor15 /. float_of_int num_iterations);

  (* Delta *)
  let time_delta = t15 -. t7 in
  let time_pct = (time_delta /. t7) *. 100.0 in
  let minor_delta = minor15 -. minor7 in
  let minor_pct = (minor_delta /. minor7) *. 100.0 in

  Printf.printf "Delta (V15 - V7):\n";
  Printf.printf "  time: %.3f s (%.1f%%)\n" time_delta time_pct;
  Printf.printf "  minor_words: %.0f (%.1f%%)\n" minor_delta minor_pct;

  Printf.printf "\n=== Verdict ===\n";
  if abs_float time_pct < 5.0 then
    Printf.printf "Time delta < 5%% — within noise.\n"
  else
    Printf.printf "Time delta: %.1f%% — real overhead detected.\n" time_pct;

  if abs_float minor_pct < 5.0 then
    Printf.printf "Allocation delta < 5%% — within noise.\n"
  else
    Printf.printf "Allocation delta: %.1f%% — real overhead detected.\n" minor_pct
