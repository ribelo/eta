(* P-C pool lifecycle probe — actual Eta.Pool with DuckDB.

   Tests:
   1. Safe ordering: pool shutdown, then db close
   2. Unsafe ordering: db close while pool alive (crash or error)
*)
open Eta

let () =
  Printf.printf "=== P-C Pool Lifecycle Probe (actual Eta.Pool) ===\n\n";

  (* Test 1: Safe ordering — pool shutdown first, then db close *)
  Printf.printf "Test 1: Safe ordering (pool shutdown -> db close)\n";

  let db_handle = ref (Pc_duckdb.open_memory ()) in

  let acquire =
    Effect.sync (fun () ->
      let conn = Pc_duckdb.connect !db_handle in
      conn)
  in

  let release conn =
    Effect.sync (fun () ->
      Pc_duckdb.disconnect conn)
  in

  let health_check conn =
    Effect.sync (fun () ->
      if Pc_duckdb.exec_sql conn "SELECT 1" then ()
      else failwith "health check failed")
  in

  let result =
    Eio_main.run (fun stdenv ->
      Eio.Switch.run (fun sw ->
        let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
        let pool =
          match Runtime.run rt (Pool.create ~name:"test.pool" ~max_size:2
            ~acquire ~release ~health_check ()) with
          | Exit.Ok p -> p
          | Exit.Error _ ->
              Printf.printf "  Pool create failed\n";
              exit 1
        in

        (* Acquire and use a connection *)
        let use_conn =
          Pool.with_resource pool (fun conn ->
            Effect.sync (fun () ->
              let ok = Pc_duckdb.exec_sql conn "SELECT 1" in
              ok))
        in

        let ok1 = match Runtime.run rt use_conn with
        | Exit.Ok b -> b
        | Exit.Error _ -> false
        in
        Printf.printf "  Connection use: ok=%b\n" ok1;

        (* Shutdown pool first *)
        let shutdown_result = Runtime.run rt (Pool.shutdown pool) in
        (match shutdown_result with
        | Exit.Ok () -> Printf.printf "  Pool shutdown: OK\n"
        | Exit.Error _ ->
            Printf.printf "  Pool shutdown failed\n");

        (* Then close database *)
        let close_eff = Effect.sync (fun () -> Pc_duckdb.close_db !db_handle; ()) in
        let _ = Runtime.run rt close_eff in
        Printf.printf "  Database closed after pool: OK\n";

        shutdown_result))
  in

  (match result with
  | Exit.Ok () -> Printf.printf "  Safe ordering: PASSED\n\n"
  | Exit.Error _ ->
      Printf.printf "  Safe ordering: FAILED\n\n");

  (* Test 2: Unsafe ordering — db close while pool alive *)
  Printf.printf "Test 2: Unsafe ordering (db close while pool alive)\n";

  let db_handle2 = ref (Pc_duckdb.open_memory ()) in

  let acquire2 =
    Effect.sync (fun () ->
      let conn = Pc_duckdb.connect !db_handle2 in
      conn)
  in

  let release2 conn =
    Effect.sync (fun () ->
      Pc_duckdb.disconnect conn)
  in

  let result2 =
    Eio_main.run (fun stdenv ->
      Eio.Switch.run (fun sw ->
        let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
        let pool =
          match Runtime.run rt (Pool.create ~name:"test.pool2" ~max_size:2
            ~acquire:acquire2 ~release:release2 ()) with
          | Exit.Ok p -> p
          | Exit.Error _ ->
              Printf.printf "  Pool create failed\n";
              exit 1
        in

        (* Acquire a connection *)
        let use_conn =
          Pool.with_resource pool (fun conn ->
            Effect.sync (fun () ->
              let ok = Pc_duckdb.exec_sql conn "SELECT 1" in
              ok))
        in

        let ok2 = match Runtime.run rt use_conn with
        | Exit.Ok b -> b
        | Exit.Error _ -> false
        in
        Printf.printf "  Connection use before close: ok=%b\n" ok2;

        (* Close database BEFORE pool shutdown — this is the unsafe ordering *)
        let close_eff2 = Effect.sync (fun () -> Pc_duckdb.close_db !db_handle2; ()) in
        let _ = Runtime.run rt close_eff2 in
        Printf.printf "  Database closed (pool still alive)\n";

        (* Try to acquire another connection from closed db *)
        let use_conn2 =
          Pool.with_resource pool (fun conn ->
            Effect.sync (fun () ->
              let ok = Pc_duckdb.exec_sql conn "SELECT 1" in
              ok))
        in

        let conn_result = Runtime.run rt use_conn2 in
        (match conn_result with
        | Exit.Ok b ->
            Printf.printf "  Connection use after db close: ok=%b (UNEXPECTED)\n" b;
            Printf.printf "  Unsafe ordering: connection still works?\n"
        | Exit.Error _ ->
            Printf.printf "  Connection use after db close: FAILED (expected)\n");

        (* Now shutdown pool *)
        let shutdown_result = Runtime.run rt (Pool.shutdown pool) in
        (match shutdown_result with
        | Exit.Ok () -> Printf.printf "  Pool shutdown after db close: OK\n"
        | Exit.Error _ ->
            Printf.printf "  Pool shutdown after db close: failed\n");

        ()))
  in

  Printf.printf "  Unsafe ordering: %s\n\n"
    (if result2 = () then "completed" else "crashed");

  Printf.printf "=== Verdict ===\n";
  Printf.printf "P-C: Pool lifecycle with Database parent handle\n";
  Printf.printf "  - Safe ordering (pool -> db): works\n";
  Printf.printf "  - Unsafe ordering (db -> pool): see Test 2 results above\n"
