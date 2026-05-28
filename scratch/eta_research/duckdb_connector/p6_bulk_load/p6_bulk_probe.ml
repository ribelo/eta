(** P6 DuckDB bulk load probe — compares insertion strategies.

    Hypothesis H-6: Appender / COPY FROM warrant first-class API; per-row
    INSERT is wrong-shaped for bulk ingestion.

    Disproof signature: Appender vs batched VALUES INSERT differ <2× for 1M
    rows; the new surface does not earn its place. *)

module D = P6_duckdb

let num_runs = 3

(* Run a strategy and collect stats *)
let run_strategy ~conn ~name ~f ~count =
  Printf.printf "\n--- %s (%d rows) ---\n" name count;
  flush stdout;

  let wall_times = ref [] in

  for run = 1 to num_runs do
    (* Clean table before each run *)
    D.exec_sql conn "DROP TABLE IF EXISTS bulk_test;";
    D.exec_sql conn "CREATE TABLE bulk_test (id BIGINT, value DOUBLE, label VARCHAR);";
    
    let (wall_us, rows) = f conn count in
    let wall_ms = wall_us /. 1000.0 in
    wall_times := wall_ms :: !wall_times;
    
    Printf.printf "  run %d: wall_ms=%.3f rows=%d\n" run wall_ms rows;
    flush stdout
  done;

  let sorted = Array.of_list !wall_times in
  Array.sort Float.compare sorted;
  let median = sorted.(Array.length sorted / 2) in
  
  Printf.printf "  median_wall_ms=%.3f\n" median;
  flush stdout;
  median

(* Compare strategies at a given scale *)
let compare_strategies ~conn ~count =
  Printf.printf "\n=== Comparing strategies (%d rows) ===\n" count;
  flush stdout;

  (* Strategy A: Per-row INSERT *)
  let wall_a = run_strategy ~conn ~name:"A: Per-row INSERT" ~f:D.per_row_insert ~count in

  (* Strategy B: Batched VALUES INSERT *)
  let wall_b = run_strategy ~conn ~name:"B: Batched VALUES INSERT" ~f:D.batched_insert ~count in

  (* Strategy C: Appender *)
  let wall_c = run_strategy ~conn ~name:"C: Appender" ~f:D.appender_insert ~count in

  (* Calculate ratios *)
  let ratio_b_a = wall_b /. wall_a in
  let ratio_c_a = wall_c /. wall_a in
  let ratio_c_b = wall_c /. wall_b in

  Printf.printf "\n  Ratios:\n";
  Printf.printf "    B/A (batched/per-row): %.2fx\n" ratio_b_a;
  Printf.printf "    C/A (appender/per-row): %.2fx\n" ratio_c_a;
  Printf.printf "    C/B (appender/batched): %.2fx\n" ratio_c_b;

  (wall_a, wall_b, wall_c, ratio_c_b)

let () =
  Printf.printf "=== P6 DuckDB Bulk Load Probe ===\n";
  Printf.printf "Hypothesis H-6: Appender warrants first-class API\n";
  Printf.printf "Runs per strategy: %d\n" num_runs;
  flush stdout;

  (* Open database *)
  let db = D.open_memory () in
  let conn = D.connect db in

  (* Test at 100k rows (faster than 1M for initial probe) *)
  let count = 100_000 in

  let (wall_a, wall_b, wall_c, ratio_c_b) = compare_strategies ~conn ~count in

  (* Cleanup *)
  D.disconnect conn;
  D.close_db db;

  (* Summary *)
  Printf.printf "\n=== Summary ===\n";
  Printf.printf "%-30s %-15s\n" "Strategy" "Wall (ms)";
  Printf.printf "%-30s %-15s\n" "--------" "---------";
  Printf.printf "%-30s %-15.3f\n" "A: Per-row INSERT" wall_a;
  Printf.printf "%-30s %-15.3f\n" "B: Batched VALUES INSERT" wall_b;
  Printf.printf "%-30s %-15.3f\n" "C: Appender" wall_c;

  (* Verdict - ratio_c_b is wall_c/wall_b, so smaller = faster *)
  let appender_speedup = wall_b /. wall_c in
  Printf.printf "\nVerdict: %s\n"
    (if appender_speedup >= 2.0 then
       Printf.sprintf "PASSED - H-6 confirmed (Appender is %.1fx faster than batched)" appender_speedup
     else
       Printf.sprintf "FAILED - H-6 falsified (Appender is only %.1fx faster than batched)" appender_speedup);

  Printf.printf "Stop condition: %s\n"
    (if appender_speedup >= 2.0 then "none (continue to P7)"
       else "Appender surface does not earn its place");
  flush stdout
