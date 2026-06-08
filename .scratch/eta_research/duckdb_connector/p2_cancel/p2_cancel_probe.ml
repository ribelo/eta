(** P2 DuckDB cancellation probe — tests duckdb_interrupt mid-query correctness.

    Hypothesis H-2: duckdb_interrupt mid-query returns DUCKDB_INTERRUPTED cleanly
    and leaves the connection / statement reusable.

    Disproof signature: connection state corrupted after interrupt, OR interrupt
    only fires at statement boundaries (not mid-query), OR statement re-execute
    fails. *)

module D = P2_duckdb

let interrupt_delay_ms = 200
let test_iterations = 10

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

(* Long-running query that takes several seconds *)
let long_query =
  {|
  SELECT
    category,
    COUNT(*) AS cnt,
    AVG(value) AS avg_val,
    STDDEV(value) AS std_val,
    SUM(value) AS total_val
  FROM (
    SELECT t1.category, t1.value
    FROM t t1
    CROSS JOIN range(1, 2000) t2(i)
  )
  GROUP BY category
  ORDER BY category;
  |}

(* Test 1: Basic interrupt — start query, wait, interrupt, check connection *)
let test_basic_interrupt conn =
  Printf.printf "\n=== Test 1: Basic Interrupt ===\n";
  flush stdout;

  let bg = D.start_background conn long_query in
  Thread.delay (float_of_int interrupt_delay_ms /. 1000.0);
  
  let (start_us, end_us, completed, interrupted) = D.interrupt_background conn bg in
  let elapsed_ms = (end_us -. start_us) /. 1000.0 in
  
  Printf.printf "query_wall_ms=%.3f\n" elapsed_ms;
  Printf.printf "query_completed=%b\n" completed;
  Printf.printf "query_interrupted=%b\n" interrupted;
  Printf.printf "connection_reusable=%b\n" (D.check_select1 conn);
  flush stdout;
  
  (not completed && D.check_select1 conn,
   Printf.sprintf "Basic interrupt: interrupted=%b, connection_ok=%b" interrupted (D.check_select1 conn))

(* Test 2: Multiple interrupt cycles — verify connection stability *)
let test_multiple_interrupts conn =
  Printf.printf "\n=== Test 2: Multiple Interrupt Cycles ===\n";
  flush stdout;

  let results = ref [] in
  for i = 1 to test_iterations do
    let bg = D.start_background conn long_query in
    Thread.delay (float_of_int interrupt_delay_ms /. 1000.0);
    
    let (_, _, completed, interrupted) = D.interrupt_background conn bg in
    let conn_ok = D.check_select1 conn in
    results := (completed, interrupted, conn_ok) :: !results;
    
    if i mod 5 = 0 then (
      Printf.printf "  iteration %d: completed=%b interrupted=%b conn_ok=%b\n" i completed interrupted conn_ok;
      flush stdout)
  done;
  
  let all_interrupted = List.for_all (fun (_, interrupted, _) -> interrupted) !results in
  let all_conn_ok = List.for_all (fun (_, _, conn_ok) -> conn_ok) !results in
  
  Printf.printf "total_iterations=%d\n" test_iterations;
  Printf.printf "all_interrupted=%b\n" all_interrupted;
  Printf.printf "all_connection_ok=%b\n" all_conn_ok;
  flush stdout;
  
  (all_interrupted && all_conn_ok,
   Printf.sprintf "Multiple interrupts: %d/%d interrupted, %d/%d connection_ok" 
     (List.length (List.filter (fun (_, i, _) -> i) !results)) test_iterations
     (List.length (List.filter (fun (_, _, c) -> c) !results)) test_iterations)

(* Test 3: Statement reuse after interrupt *)
let test_statement_reuse conn =
  Printf.printf "\n=== Test 3: Statement Reuse After Interrupt ===\n";
  flush stdout;

  (* First, interrupt a query *)
  let bg = D.start_background conn long_query in
  Thread.delay (float_of_int interrupt_delay_ms /. 1000.0);
  let _ = D.interrupt_background conn bg in
  
  (* Now try to run a simple query *)
  let simple_ok = D.check_select1 conn in
  
  (* Try running another long query and interrupt it *)
  let bg2 = D.start_background conn long_query in
  Thread.delay (float_of_int interrupt_delay_ms /. 1000.0);
  let (_, _, completed2, interrupted2) = D.interrupt_background conn bg2 in
  let conn_ok2 = D.check_select1 conn in
  
  Printf.printf "simple_query_after_interrupt=%b\n" simple_ok;
  Printf.printf "second_interrupt_completed=%b\n" completed2;
  Printf.printf "second_interrupt_interrupted=%b\n" interrupted2;
  Printf.printf "connection_ok_after_second=%b\n" conn_ok2;
  flush stdout;
  
  (simple_ok && interrupted2 && conn_ok2,
   Printf.sprintf "Statement reuse: simple_ok=%b, second_interrupt=%b, conn_ok=%b" 
     simple_ok interrupted2 conn_ok2)

(* Test 4: Interrupt latency measurement *)
let test_interrupt_latency conn =
  Printf.printf "\n=== Test 4: Interrupt Latency ===\n";
  flush stdout;

  let latencies = ref [] in
  for _ = 1 to 5 do
    let bg = D.start_background conn long_query in
    Thread.delay (float_of_int interrupt_delay_ms /. 1000.0);
    
    let before_interrupt = D.monotonic_us () in
    let (_, _, _, _) = D.interrupt_background conn bg in
    let after_return = D.monotonic_us () in
    
    let interrupt_to_return_ms = (after_return -. before_interrupt) /. 1000.0 in
    latencies := interrupt_to_return_ms :: !latencies;
    
    ignore (D.check_select1 conn)
  done;
  
  let sorted = Array.of_list !latencies in
  Array.sort Float.compare sorted;
  let p50 = sorted.(Array.length sorted / 2) in
  let max_lat = sorted.(Array.length sorted - 1) in
  
  Printf.printf "interrupt_latency_p50_ms=%.3f\n" p50;
  Printf.printf "interrupt_latency_max_ms=%.3f\n" max_lat;
  Printf.printf "samples=%d\n" (Array.length sorted);
  flush stdout;
  
  (max_lat < 500.0, (* Should be well under 500ms *)
   Printf.sprintf "Interrupt latency: p50=%.3fms, max=%.3fms" p50 max_lat)

let () =
  Printf.printf "=== P2 DuckDB Cancellation Probe ===\n";
  Printf.printf "Hypothesis H-2: duckdb_interrupt mid-query is clean and connection reusable\n";
  Printf.printf "Interrupt delay: %dms\n" interrupt_delay_ms;
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
  
  let passed, msg = test_basic_interrupt conn in
  results := (passed, msg) :: !results;
  
  let passed, msg = test_multiple_interrupts conn in
  results := (passed, msg) :: !results;
  
  let passed, msg = test_statement_reuse conn in
  results := (passed, msg) :: !results;
  
  let passed, msg = test_interrupt_latency conn in
  results := (passed, msg) :: !results;

  (* Cleanup *)
  D.disconnect conn;
  D.close_db db;

  (* Summary *)
  Printf.printf "\n=== Summary ===\n";
  let all_passed = List.for_all fst !results in
  List.iter (fun (_, msg) -> Printf.printf "  %s\n" msg) (List.rev !results);
  Printf.printf "\nVerdict: %s\n"
    (if all_passed then "PASSED - H-2 confirmed" else "FAILED - H-2 falsified");
  Printf.printf "Stop condition: %s\n"
    (if all_passed then "none (continue to P3)"
       else "P2 failed - lab must stop and re-plan cancellation strategy");
  flush stdout
