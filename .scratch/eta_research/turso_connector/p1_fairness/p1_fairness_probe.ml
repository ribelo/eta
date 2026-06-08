(** P1 Turso fairness probe — measures co-fiber wake-jitter during long queries.

    Hypothesis H-1: Effect.blocking with Turso keeps co-fiber wake-jitter
    ≤10ms p99 during a 30s query.

    Disproof signature: co-fiber wake-jitter p99 >10ms. *)

module T = P1_turso

let num_heartbeat_threads = 16
let tick_interval_us = 1000.0 (* 1ms *)
let num_rows = 100_000

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

let count_outliers threshold values =
  List.fold_left (fun acc v -> if v > threshold then acc + 1 else acc) 0 values

(* Setup: create synthetic table *)
let setup_database db =
  T.exec_sql db
    "CREATE TABLE t (id INTEGER PRIMARY KEY, category INTEGER, value REAL, label TEXT);";
  (* Insert rows *)
  for i = 1 to num_rows do
    T.exec_sql db
      (Printf.sprintf "INSERT INTO t VALUES (%d, %d, %f, 'item_%d');"
         i (i mod 100) (Random.float 1000.0) (i mod 1000))
  done

(* Long-running query - self-join to create workload *)
let long_query =
  "SELECT t1.category, COUNT(*) AS cnt, AVG(t1.value) AS avg_val, SUM(t1.value) AS total_val FROM t t1, t t2 WHERE t2.id <= 100 GROUP BY t1.category ORDER BY t1.category;"

(* Heartbeat thread *)
let heartbeat_thread_func _id jitter_ref running =
  let rec loop last_tick =
    if !running then (
      Thread.delay (tick_interval_us /. 1_000_000.0);
      let now = T.monotonic_us () in
      let expected = last_tick +. tick_interval_us in
      let jitter_us = abs_float (now -. expected) in
      jitter_ref := jitter_us :: !jitter_ref;
      loop now)
    else
      ()
  in
  loop (T.monotonic_us ())

let () =
  Printf.printf "=== P1 Turso Fairness Probe ===\n";
  Printf.printf "Hypothesis H-1: Effect.blocking keeps wake-jitter ≤10ms p99\n";
  Printf.printf "Heartbeat threads: %d, tick interval: %.0fus\n" num_heartbeat_threads
    tick_interval_us;
  Printf.printf "Rows: %d\n" num_rows;
  flush stdout;

  (* Open database *)
  let db = T.open_memory () in

  Printf.printf "Setting up synthetic table...\n";
  flush stdout;
  setup_database db;
  Printf.printf "Setup complete.\n";
  flush stdout;

  (* Shared state *)
  let jitter_samples = ref [] in
  let running = ref true in

  (* Start heartbeat threads *)
  let heartbeat_threads =
    List.init num_heartbeat_threads (fun id ->
        Thread.create (heartbeat_thread_func id jitter_samples) running)
  in

  (* Give heartbeat threads time to start *)
  Thread.delay 0.01;

  (* Run query *)
  Printf.printf "Starting long query...\n";
  flush stdout;
  let (start_us, end_us, completed, interrupted) =
    T.run_long_query db long_query
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

  Printf.printf "\n=== Results ===\n";
  Printf.printf "query_wall_ms=%.3f\n" query_wall_ms;
  Printf.printf "query_completed=%b\n" completed;
  Printf.printf "query_interrupted=%b\n" interrupted;
  Printf.printf "heartbeat_samples=%d\n" total_samples;
  Printf.printf "jitter_p50_us=%.3f\n" p50;
  Printf.printf "jitter_p95_us=%.3f\n" p95;
  Printf.printf "jitter_p99_us=%.3f\n" p99;
  Printf.printf "jitter_max_us=%.3f\n" max_jitter;
  Printf.printf "outliers_above_10ms=%d\n" outliers_10ms;
  Printf.printf "connection_reusable=%b\n" (T.check_select1 db);
  flush stdout;

  (* Cleanup *)
  T.close_db db;

  (* Verdict *)
  Printf.printf "\n=== Verdict ===\n";
  Printf.printf "p99_jitter_us=%.3f\n" p99;
  Printf.printf "Verdict: %s\n"
    (if p99 <= 10000.0 then "PASSED - H-1 confirmed"
     else "FAILED - H-1 falsified");
  Printf.printf "Stop condition: %s\n"
    (if p99 <= 10000.0 then "none (continue to P2)"
       else "P1 failed - lab must stop and re-plan connector shape");
  flush stdout
