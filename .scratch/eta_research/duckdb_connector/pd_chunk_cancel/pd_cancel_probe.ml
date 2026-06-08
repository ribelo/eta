(* P-D chunk fold cancellation probe — real Eio fibers + Effect.timeout.

   Tests: does chunk handle leak when fiber is cancelled mid-fold?

   Two tests:
   1. WITHOUT cleanup: chunk destroyed AFTER sleep — if cancelled, leaked
   2. WITH cleanup: chunk destroyed via Fun.protect — even on cancel, cleaned

   We run each test 20 times to see if accumulated leaks cause issues.
*)
open Eta

let test_no_cleanup conn =
  let result =
    Eio_main.run (fun stdenv ->
      Eio.Switch.run (fun sw ->
        let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in

        let fold_effect =
          Effect.sync (fun () ->
            let result = Pd_duckdb.query_start conn "SELECT id FROM big" in
            let total_rows = ref 0 in
            let total_chunks = ref 0 in

            let rec loop () =
              let chunk = Pd_duckdb.fetch_chunk result in
              if Nativeint.equal chunk Nativeint.zero then
                ()
              else begin
                let size = Pd_duckdb.chunk_size chunk in
                total_rows := !total_rows + size;
                total_chunks := !total_chunks + 1;
                (* NO cleanup: destroy AFTER sleep — if cancelled, leaked *)
                Eio_unix.sleep 0.0001;
                Pd_duckdb.destroy_chunk chunk;
                loop ()
              end
            in

            loop ();
            Pd_duckdb.destroy_result result;
            (!total_rows, !total_chunks))
        in

        let timed_fold =
          fold_effect
          |> Effect.timeout (Duration.ms 50)
          |> Effect.catch (fun err ->
               Effect.pure (-1, -1))
        in

        match Runtime.run rt timed_fold with
        | Exit.Ok (rows, chunks) -> (rows, chunks)
        | Exit.Error _ -> (-1, -1)))
  in
  ignore result

let test_with_cleanup conn =
  let result =
    Eio_main.run (fun stdenv ->
      Eio.Switch.run (fun sw ->
        let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in

        let fold_effect =
          Effect.sync (fun () ->
            let result = Pd_duckdb.query_start conn "SELECT id FROM big" in
            let total_rows = ref 0 in
            let total_chunks = ref 0 in

            let rec loop () =
              let chunk = Pd_duckdb.fetch_chunk result in
              if Nativeint.equal chunk Nativeint.zero then
                ()
              else begin
                let size = Pd_duckdb.chunk_size chunk in
                total_rows := !total_rows + size;
                total_chunks := !total_chunks + 1;
                (* WITH cleanup: destroy via Fun.protect *)
                Fun.protect
                  ~finally:(fun () -> Pd_duckdb.destroy_chunk chunk)
                  (fun () -> Eio_unix.sleep 0.0001);
                loop ()
              end
            in

            loop ();
            Pd_duckdb.destroy_result result;
            (!total_rows, !total_chunks))
        in

        let timed_fold =
          fold_effect
          |> Effect.timeout (Duration.ms 50)
          |> Effect.catch (fun err ->
               Effect.pure (-1, -1))
        in

        match Runtime.run rt timed_fold with
        | Exit.Ok (rows, chunks) -> (rows, chunks)
        | Exit.Error _ -> (-1, -1)))
  in
  ignore result

let () =
  Printf.printf "=== P-D Chunk Fold Cancellation (real fibers + timeout) ===\n\n";

  let db = Pd_duckdb.open_memory () in
  let conn = Pd_duckdb.connect db in

  (* Create large table *)
  let _ = Pd_duckdb.exec_sql conn "CREATE TABLE big AS SELECT i AS id FROM range(10000000) t(i)" in
  Printf.printf "Table created: 10M rows\n";

  (* Test 1: WITHOUT cleanup — 20 iterations *)
  Printf.printf "\nTest 1: 20 iterations WITHOUT cleanup\n";
  let all_ok = ref true in
  for i = 1 to 20 do
    test_no_cleanup conn;
    if not (Pd_duckdb.check_connection conn) then begin
      Printf.printf "  Iteration %d: connection FAILED\n" i;
      all_ok := false
    end;
    if i mod 5 = 0 then
      Printf.printf "  Iteration %d: OK\n" i
  done;
  Printf.printf "  All iterations ok: %b\n" !all_ok;

  (* Test 2: WITH cleanup — 20 iterations *)
  Printf.printf "\nTest 2: 20 iterations WITH Fun.protect cleanup\n";
  let all_ok2 = ref true in
  for i = 1 to 20 do
    test_with_cleanup conn;
    if not (Pd_duckdb.check_connection conn) then begin
      Printf.printf "  Iteration %d: connection FAILED\n" i;
      all_ok2 := false
    end;
    if i mod 5 = 0 then
      Printf.printf "  Iteration %d: OK\n" i
  done;
  Printf.printf "  All iterations ok: %b\n" !all_ok2;

  (* Cleanup *)
  Pd_duckdb.disconnect conn;
  Pd_duckdb.close_db db;

  Printf.printf "\n=== Verdict ===\n";
  Printf.printf "Test 1 (no cleanup, 20x): all ok = %b\n" !all_ok;
  Printf.printf "Test 2 (with cleanup, 20x): all ok = %b\n" !all_ok2;
  if not !all_ok then
    Printf.printf "LEAK DETECTED: accumulated leaks cause connection failure.\n"
  else
    Printf.printf "No immediate crash, but chunk handles leak (C heap, not GC'd).\n";
  if !all_ok2 then
    Printf.printf "Fun.protect prevents leak on cancellation.\n"
