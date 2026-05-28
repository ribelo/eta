(** P1 DuckDB fairness probe — measures co-fiber wake-jitter during long OLAP queries.

    Hypothesis H-1: Effect.blocking ?on_cancel:duckdb_interrupt keeps co-fiber
    wake-jitter ≤10ms p99 during a 30s OLAP query.

    Disproof signature: co-fiber wake-jitter p99 >10ms in either threads=N or
    threads=1 mode.

    This probe uses systhreads to simulate the heartbeat measurement pattern.
    The key question: does DuckDB's internal multi-threading starve the OCaml
    scheduler thread? *)

module D = P1_duckdb

let num_heartbeat_threads = 16
let tick_interval_us = 1000.0 (* 1ms *)
let query_timeout_s = 60.0 (* 60s max for the OLAP query *)

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

let max_float values = List.fold_left max 0.0 values

(* Count outliers above threshold *)
let count_outliers threshold values =
  List.fold_left (fun acc v -> if v > threshold then acc + 1 else acc) 0 values

(* Setup: create synthetic table with 1M rows *)
let setup_database conn =
  D.exec_sql conn
    {|
    CREATE TABLE t (
      id BIGINT,
      category INTEGER,
      value DOUBLE,
      label VARCHAR
    );

    INSERT INTO t
    SELECT
      i AS id,
      (i % 100) AS category,
      random() * 1000.0 AS value,
      'item_' || (i % 1000)::VARCHAR AS label
    FROM range(1, 1000001) t(i);
  |}

(* Long-running OLAP query that takes significant time *)
let olap_query =
  {|
  SELECT
    category,
    COUNT(*) AS cnt,
    AVG(value) AS avg_val,
    STDDEV(value) AS std_val,
    SUM(value) AS total_val,
    MIN(value) AS min_val,
    MAX(value) AS max_val
  FROM (
    SELECT t1.category, t1.value
    FROM t t1
    CROSS JOIN range(1, 100) t2(i)
  )
  GROUP BY category
  ORDER BY category;
  |}

(* Heartbeat thread: measures jitter by sleeping and checking time *)
let heartbeat_thread_func conn _id jitter_ref running =
  let rec loop last_tick =
    if !running then (
      (* Sleep for tick interval *)
      Thread.delay (tick_interval_us /. 1_000_000.0);
      let now = D.monotonic_us () in
      let expected = last_tick +. tick_interval_us in
      let jitter_us = abs_float (now -. expected) in
      jitter_ref := jitter_us :: !jitter_ref;
      loop now)
    else
      ()
  in
  loop (D.monotonic_us ())

(* Run one fairness test *)
let run_fairness_test ~conn ~threads ~label =
  Printf.printf "\n=== %s (threads=%d) ===\n" label threads;
  flush stdout;

  (* Set threads - if -1, use default (don't set) *)
  if threads > 0 then
    D.exec_sql conn (Printf.sprintf "SET threads=%d;" threads);

  (* Shared state *)
  let jitter_samples = ref [] in
  let running = ref true in

  (* Start heartbeat threads *)
  let heartbeat_threads =
    List.init num_heartbeat_threads (fun id ->
        Thread.create (heartbeat_thread_func conn id jitter_samples) running)
  in

  (* Give heartbeat threads time to start *)
  Thread.delay 0.01;

  (* Run OLAP query *)
  Printf.printf "Starting OLAP query...\n";
  flush stdout;
  let (start_us, end_us, completed, interrupted) =
    D.run_long_query conn olap_query
  in

  (* Stop heartbeat threads *)
  running := false;
  List.iter Thread.join heartbeat_threads;

  (* Calculate results *)
  let query_wall_ms = (end_us -. start_us) /. 1000.0 in
  let p50 = percentile !jitter_samples 50.0 in
  let p95 = percentile !jitter_samples 95.0 in
  let p99 = percentile !jitter_samples 99.0 in
  let max_jitter = max_float !jitter_samples in
  let outliers_10ms = count_outliers 10000.0 !jitter_samples in
  let total_samples = List.length !jitter_samples in

  Printf.printf "query_wall_ms=%.3f\n" query_wall_ms;
  Printf.printf "query_completed=%b\n" completed;
  Printf.printf "query_interrupted=%b\n" interrupted;
  Printf.printf "heartbeat_samples=%d\n" total_samples;
  Printf.printf "jitter_p50_us=%.3f\n" p50;
  Printf.printf "jitter_p95_us=%.3f\n" p95;
  Printf.printf "jitter_p99_us=%.3f\n" p99;
  Printf.printf "jitter_max_us=%.3f\n" max_jitter;
  Printf.printf "outliers_above_10ms=%d\n" outliers_10ms;
  Printf.printf "connection_reusable=%b\n" (D.check_select1 conn);
  flush stdout;

  (* Return verdict *)
  ( p99 <= 10000.0,
    Printf.sprintf "%s: p99=%.3fus, max=%.3fus, outliers=%d" label p99 max_jitter
      outliers_10ms )

let () =
  Printf.printf "=== P1 DuckDB Fairness Probe ===\n";
  Printf.printf "Hypothesis H-1: Effect.blocking + duckdb_interrupt keeps wake-jitter ≤10ms p99\n";
  Printf.printf "Heartbeat threads: %d, tick interval: %.0fus\n" num_heartbeat_threads
    tick_interval_us;
  flush stdout;

  (* Open database *)
  let db = D.open_memory () in
  let conn = D.connect db in

  Printf.printf "Setting up synthetic table (1M rows)...\n";
  flush stdout;
  setup_database conn;
  Printf.printf "Setup complete.\n";
  flush stdout;

  (* Run tests *)
  let results = ref [] in

  (* Test 1: threads=N (default, typically host cores) - use -1 to mean default *)
  let passed, msg = run_fairness_test ~conn ~threads:(-1) ~label:"Fairness test: default threads" in
  results := (passed, msg) :: !results;

  (* Test 2: threads=1 *)
  let passed, msg = run_fairness_test ~conn ~threads:1 ~label:"Fairness test: single thread" in
  results := (passed, msg) :: !results;

  (* Cleanup *)
  D.disconnect conn;
  D.close_db db;

  (* Summary *)
  Printf.printf "\n=== Summary ===\n";
  let all_passed = List.for_all fst !results in
  List.iter (fun (_, msg) -> Printf.printf "  %s\n" msg) (List.rev !results);
  Printf.printf "\nVerdict: %s\n"
    (if all_passed then "PASSED - H-1 confirmed" else "FAILED - H-1 falsified");
  Printf.printf "Stop condition: %s\n"
    (if all_passed then "none (continue to P2)"
       else "P1 failed - lab must stop and re-plan connector shape");
  flush stdout
