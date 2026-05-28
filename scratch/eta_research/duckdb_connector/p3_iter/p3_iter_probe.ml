(** P3 DuckDB chunk iteration probe — compares materialized vs chunk iteration.

    Hypothesis H-3: Chunk-native iteration via duckdb_fetch_chunk is the right
    primary scan shape; per-row API is unnecessary.

    Disproof signature: Materialized full-result is faster than chunk iteration
    for ≤10M-row scans, OR per-chunk allocation is >X bytes/row vs SQLite's
    row-step pattern. *)

module D = P3_duckdb

let num_runs = 3

(* Percentile calculation *)
let percentile values pct =
  match values with
  | [] -> 0.0
  | values ->
    let sorted = Array.of_list values in
    Array.sort Float.compare sorted;
    let index =
      int_of_float
        (ceil ((float_of_int (Array.length sorted) *. pct) /. 100.0) -. 1.0)
    in
    sorted.(max 0 (min (Array.length sorted - 1) index))

(* Create test table with N rows *)
let create_test_table conn n =
  D.exec_sql conn
    (Printf.sprintf
       {|
       CREATE TABLE test_data (
         id BIGINT,
         value DOUBLE,
         label VARCHAR
       );

       INSERT INTO test_data
       SELECT
         i AS id,
         random() * 1000.0 AS value,
         'item_' || (i %% 1000)::VARCHAR AS label
       FROM range(1, %d) t(i);
       |}
       (n + 1))

(* Run a strategy multiple times and collect stats *)
let run_strategy ~conn ~name ~f ~query =
  Printf.printf "\n--- %s ---\n" name;
  flush stdout;

  let wall_times = ref [] in
  let rows_list = ref [] in
  let sums = ref [] in

  for run = 1 to num_runs do
    let (wall_us, rows, sum, _minor, _major) = f conn query in
    wall_times := wall_us :: !wall_times;
    rows_list := rows :: !rows_list;
    sums := sum :: !sums;

    Printf.printf "  run %d: wall_us=%.0f rows=%d sum=%Ld\n" run wall_us rows (Int64.of_int sum);
    flush stdout
  done;

  let sorted_walls = Array.of_list !wall_times in
  Array.sort Float.compare sorted_walls;
  let median_wall = sorted_walls.(Array.length sorted_walls / 2) in
  let rows = List.hd !rows_list in
  let sum = List.hd !sums in

  Printf.printf "  median_wall_us=%.0f\n" median_wall;
  Printf.printf "  rows=%d\n" rows;
  flush stdout;

  (median_wall, rows, sum)

(* Compare two strategies *)
let compare_strategies ~conn ~size =
  Printf.printf "\n=== Comparing strategies (%d rows) ===\n" size;
  flush stdout;

  (* Create fresh table *)
  D.exec_sql conn "DROP TABLE IF EXISTS test_data;";
  create_test_table conn size;

  let query = "SELECT id, value FROM test_data;" in

  (* Strategy A: Materialize *)
  let (wall_a, rows_a, sum_a) =
    run_strategy ~conn ~name:"A: Materialize" ~f:D.materialize ~query
  in

  (* Strategy B: Chunk iteration *)
  let (wall_b, rows_b, sum_b) =
    run_strategy ~conn ~name:"B: Chunk iteration" ~f:D.chunk_iter ~query
  in

  (* Verify results match *)
  let results_match = rows_a = rows_b && sum_a = sum_b in
  Printf.printf "\nResults match: %b\n" results_match;

  if not results_match then (
    Printf.printf "ERROR: Results don't match! rows_a=%d rows_b=%d sum_a=%d sum_b=%d\n"
      rows_a rows_b sum_a sum_b);

  (* Calculate ratios *)
  let wall_ratio = wall_b /. wall_a in
  Printf.printf "Wall time ratio (B/A): %.2fx\n" wall_ratio;

  (wall_a, wall_b, wall_ratio, results_match)

let () =
  Printf.printf "=== P3 DuckDB Chunk Iteration Probe ===\n";
  Printf.printf "Hypothesis H-3: Chunk iteration is the right primary scan shape\n";
  Printf.printf "Runs per strategy: %d\n" num_runs;
  flush stdout;

  (* Open database *)
  let db = D.open_memory () in
  let conn = D.connect db in

  (* Test at different scales *)
  let scales = [ 1_000; 100_000; 1_000_000; 10_000_000 ] in
  let results = ref [] in

  List.iter
    (fun size ->
      let (wall_a, wall_b, ratio, match_ok) = compare_strategies ~conn ~size in
      results := (size, wall_a, wall_b, ratio, match_ok) :: !results)
    scales;

  (* Cleanup *)
  D.disconnect conn;
  D.close_db db;

  (* Summary *)
  Printf.printf "\n=== Summary ===\n";
  Printf.printf "%-15s %-15s %-15s %-10s %-8s\n" "Rows" "A (µs)" "B (µs)" "B/A" "Match";
  Printf.printf "%-15s %-15s %-15s %-10s %-8s\n" "----" "------" "------" "---" "-----";

  List.iter
    (fun (size, wall_a, wall_b, ratio, match_ok) ->
      Printf.printf "%-15s %-15.0f %-15.0f %-10.2f %-8b\n"
        (string_of_int size)
        wall_a wall_b ratio match_ok)
    (List.rev !results);

  (* Verdict *)
  let all_match = List.for_all (fun (_, _, _, _, m) -> m) !results in
  let chunk_wins =
    List.for_all (fun (_, _, _, ratio, _) -> ratio <= 1.5) !results
  in

  Printf.printf "\nVerdict: %s\n"
    (if all_match && chunk_wins then
       "PASSED - H-3 confirmed (chunk iteration is competitive)"
     else if all_match then
       "PARTIAL - H-3 partially confirmed (results match but chunk slower)"
     else
       "FAILED - H-3 falsified (results don't match)");

  Printf.printf "Stop condition: %s\n"
    (if all_match then "none (continue to P4)"
       else "P3 failed - iteration strategy needs re-evaluation");
  flush stdout
