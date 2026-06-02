(* Regression guard for the LadybugDB C stub query-result leak on the exception
   path. A mock liblbug (ladybug_mock_lib.c) reports an Arrow-schema error so
   [materialize_arrow_rows] raises while the query result is still live. The
   mock counts created vs destroyed query results and writes the totals to
   ETA_LADYBUG_MOCK_STATE. If the stub leaks the result when the OCaml exception
   unwinds, created stays ahead of destroyed even after a full GC.

   This binary is isolated from the main connector tests because the mock must
   be the process-wide loaded library (ETA_LADYBUG_LIBRARY), set before any
   ladybug API call triggers the one-shot library load. *)

let read_state path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let line = input_line ic in
      match String.split_on_char ' ' (String.trim line) with
      | [ created; destroyed ] -> (int_of_string created, int_of_string destroyed)
      | _ -> Alcotest.failf "unexpected mock state line: %S" line)

let test_query_result_not_leaked_on_materialize_failure () =
  let open Eta_ladybug in
  (match available () with
  | Ok () -> ()
  | Error err -> Alcotest.failf "mock ladybug library unavailable: %a" pp_error err);
  let state =
    match Sys.getenv_opt "ETA_LADYBUG_MOCK_STATE" with
    | Some path when path <> "" -> path
    | _ -> Alcotest.fail "ETA_LADYBUG_MOCK_STATE is not configured"
  in
  let query =
    Query.(
      match_ (Pattern.path [ Pattern.node ~as_:"n" ~labels:[ "N" ] () ])
      |> returning [ "n" ] ~decode:Decode.(string "n"))
  in
  let db =
    match Database.open_memory () with
    | Ok db -> db
    | Error err -> Alcotest.failf "open_memory: %a" pp_error err
  in
  let conn =
    match Connection.connect db with
    | Ok conn -> conn
    | Error err -> Alcotest.failf "connect: %a" pp_error err
  in
  (match Connection.query conn query with
  | Ok _ -> Alcotest.fail "expected the mock query to fail during materialization"
  | Error _ -> ());
  (* The query result is only reachable through the C custom block that owns it;
     once the exception unwound, that block is unreachable, so a full GC must run
     its finalizer (which destroys the result). *)
  Gc.full_major ();
  Gc.full_major ();
  let created, destroyed = read_state state in
  Alcotest.(check bool) "at least one query result was created" true (created >= 1);
  Alcotest.(check int) "every created query result was destroyed (no leak)"
    created destroyed

let () =
  Alcotest.run "eta_ladybug_leak"
    [
      ( "stub-cleanup",
        [
          Alcotest.test_case "query result not leaked on materialize failure"
            `Quick test_query_result_not_leaked_on_materialize_failure;
        ] );
    ]
