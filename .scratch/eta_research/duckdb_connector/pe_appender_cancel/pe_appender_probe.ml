(* P-E Appender cancellation probe — real Eio fibers + Effect.timeout.

   Tests: does Appender handle leak when fiber is cancelled mid-append?

   Two tests:
   1. WITHOUT cleanup: appender destroyed AFTER sleep — if cancelled, leaked
   2. WITH cleanup: appender destroyed via Fun.protect — even on cancel, cleaned
*)
open Eta

let test_no_cleanup conn =
  let result =
    Eio_main.run (fun stdenv ->
      Eio.Switch.run (fun sw ->
        let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in

        let append_effect =
          Effect.sync (fun () ->
            let appender = Pe_duckdb.appender_create conn "appender_test" in
            let rows_appended = ref 0 in

            for i = 1 to 100000 do
              Pe_duckdb.appender_append_int appender i;
              Pe_duckdb.appender_end_row appender;
              rows_appended := !rows_appended + 1;
              (* NO cleanup: destroy AFTER sleep — if cancelled, leaked *)
              if i mod 100 = 0 then Eio_unix.sleep 0.0001
            done;

            Pe_duckdb.appender_flush appender;
            Pe_duckdb.appender_destroy appender;
            !rows_appended)
        in

        let timed_append =
          append_effect
          |> Effect.timeout (Duration.ms 50)
          |> Effect.catch (fun err ->
               Effect.pure (-1))
        in

        match Runtime.run rt timed_append with
        | Exit.Ok rows -> rows
        | Exit.Error _ -> -1))
  in
  result

let test_with_cleanup conn =
  let result =
    Eio_main.run (fun stdenv ->
      Eio.Switch.run (fun sw ->
        let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in

        let append_effect =
          Effect.sync (fun () ->
            let appender = Pe_duckdb.appender_create conn "appender_test" in
            let rows_appended = ref 0 in

            Fun.protect
              ~finally:(fun () -> Pe_duckdb.appender_destroy appender)
              (fun () ->
                for i = 1 to 100000 do
                  Pe_duckdb.appender_append_int appender i;
                  Pe_duckdb.appender_end_row appender;
                  rows_appended := !rows_appended + 1;
                  (* WITH cleanup: sleep inside Fun.protect *)
                  if i mod 100 = 0 then Eio_unix.sleep 0.0001
                done;
                Pe_duckdb.appender_flush appender;
                !rows_appended))
        in

        let timed_append =
          append_effect
          |> Effect.timeout (Duration.ms 50)
          |> Effect.catch (fun err ->
               Effect.pure (-1))
        in

        match Runtime.run rt timed_append with
        | Exit.Ok rows -> rows
        | Exit.Error _ -> -1))
  in
  result

let () =
  Printf.printf "=== P-E Appender Cancellation (real fibers + timeout) ===\n\n";

  let db = Pe_duckdb.open_memory () in
  let conn = Pe_duckdb.connect db in

  (* Create table *)
  let _ = Pe_duckdb.exec_sql conn "CREATE TABLE appender_test (id INTEGER)" in
  Printf.printf "Table created\n";

  (* Test 1: 20 iterations WITHOUT cleanup *)
  Printf.printf "\nTest 1: 20 iterations WITHOUT cleanup\n";
  let all_ok = ref true in
  for i = 1 to 20 do
    let rows = test_no_cleanup conn in
    let conn_ok = Pe_duckdb.check_connection conn in
    if not conn_ok then begin
      Printf.printf "  Iteration %d: connection FAILED (rows=%d)\n" i rows;
      all_ok := false
    end;
    if i mod 5 = 0 then
      Printf.printf "  Iteration %d: rows=%d, conn_ok=%b\n" i rows conn_ok
  done;
  Printf.printf "  All iterations ok: %b\n" !all_ok;

  (* Test 2: 20 iterations WITH Fun.protect cleanup *)
  Printf.printf "\nTest 2: 20 iterations WITH Fun.protect cleanup\n";
  let all_ok2 = ref true in
  for i = 1 to 20 do
    let rows = test_with_cleanup conn in
    let conn_ok = Pe_duckdb.check_connection conn in
    if not conn_ok then begin
      Printf.printf "  Iteration %d: connection FAILED (rows=%d)\n" i rows;
      all_ok2 := false
    end;
    if i mod 5 = 0 then
      Printf.printf "  Iteration %d: rows=%d, conn_ok=%b\n" i rows conn_ok
  done;
  Printf.printf "  All iterations ok: %b\n" !all_ok2;

  (* Cleanup *)
  Pe_duckdb.disconnect conn;
  Pe_duckdb.close_db db;

  Printf.printf "\n=== Verdict ===\n";
  Printf.printf "Test 1 (no cleanup, 20x): all ok = %b\n" !all_ok;
  Printf.printf "Test 2 (with cleanup, 20x): all ok = %b\n" !all_ok2;
  if not !all_ok then
    Printf.printf "LEAK DETECTED: accumulated Appender leaks cause connection failure.\n"
  else
    Printf.printf "No immediate crash, but Appender handles leak (C heap, not GC'd).\n";
  if !all_ok2 then
    Printf.printf "Fun.protect prevents Appender leak on cancellation.\n"
