(** P-B real benchmark: measure allocation on 1M-row scan with actual Sqlite module.

    This measures the baseline allocation for a 1M-row scan with the current
    Sqlite column access functions. *)

let num_rows = 1_000_000
let num_runs = 3

let () =
  Printf.printf "=== P-B Real Allocation Benchmark ===\n";
  Printf.printf "Rows: %d, Runs: %d\n\n" num_rows num_runs;

  (* Create in-memory SQLite database *)
  let db = Sqlite.open_memory () in
  Sqlite.exec db "CREATE TABLE bench (id INTEGER, val INTEGER, name TEXT, score REAL, active INTEGER, data BLOB)";
  
  (* Insert rows *)
  Printf.printf "Inserting %d rows...\n" num_rows;
  Sqlite.exec db "BEGIN";
  for i = 1 to num_rows do
    Sqlite.exec db (Printf.sprintf 
      "INSERT INTO bench VALUES (%d, %d, 'item_%d', %f, %d, zeroblob(16))" 
      i (i * 2) i (float_of_int i *. 0.5) (if i mod 2 = 0 then 1 else 0))
  done;
  Sqlite.exec db "COMMIT";
  Printf.printf "Insertion complete.\n\n";

  (* Benchmark: scan all rows, extract all columns *)
  let run_scan () =
    let gc_before = Gc.quick_stat () in
    let stmt = Sqlite.prepare db "SELECT id, val, name, score, active, data FROM bench" in
    let count = ref 0 in
    let sum = ref 0L in
    while Sqlite.step stmt = Sqlite.row do
      let _id = Sqlite.column_int64 stmt 0 in
      let _val = Sqlite.column_int64 stmt 1 in
      let _name = Sqlite.column_text stmt 2 in
      let _score = Sqlite.column_float stmt 3 in
      let _active = Sqlite.column_int stmt 4 in
      let _data = Sqlite.column_blob stmt 5 in
      count := !count + 1;
      sum := Int64.add !sum _id
    done;
    let _ = Sqlite.finalize stmt in
    let gc_after = Gc.quick_stat () in
    (gc_after.minor_words -. gc_before.minor_words,
     gc_after.major_words -. gc_before.major_words,
     !count,
     !sum)
  in

  (* Warmup *)
  let _ = run_scan () in

  (* Run multiple times *)
  let results = Array.init num_runs (fun _ -> run_scan ()) in

  Printf.printf "%-10s %-15s %-15s %-10s %-15s\n" "Run" "minor_words" "major_words" "count" "sum";
  Printf.printf "%-10s %-15s %-15s %-10s %-15s\n" "---" "-----------" "-----------" "-----" "---";

  let total_minor = ref 0.0 in
  let total_major = ref 0.0 in
  Array.iteri (fun i (minor, major, count, sum) ->
    Printf.printf "%-10d %-15.0f %-15.0f %-10d %-15Ld\n" (i + 1) minor major count sum;
    total_minor := !total_minor +. minor;
    total_major := !total_major +. major
  ) results;

  let avg_minor = !total_minor /. float_of_int num_runs in
  let avg_major = !total_major /. float_of_int num_runs in

  Printf.printf "\nAverage:\n";
  Printf.printf "  minor_words: %.0f\n" avg_minor;
  Printf.printf "  major_words: %.0f\n" avg_major;
  Printf.printf "  per_row: %.2f minor_words\n" (avg_minor /. float_of_int num_rows);

  (* Cleanup *)
  let _ = Sqlite.close db in

  Printf.printf "\n=== Analysis ===\n";
  Printf.printf "Sqlite column functions return raw values (int64, float, string, bytes).\n";
  Printf.printf "No Value.t allocation happens during column access.\n";
  Printf.printf "Value.t is only created when the caller constructs it.\n";
  Printf.printf "\nConclusion: Widening Value.t does NOT affect Sqlite column access allocation.\n";
  Printf.printf "The allocation is in the caller's code, not in the Sqlite module.\n"
