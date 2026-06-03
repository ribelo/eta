(* Regression guard for the LadybugDB C stub query-result leak on the exception
   path. A mock liblbug (ladybug_mock_lib.c) reports an Arrow-schema error so
   [materialize_arrow_rows] raises while the query result is still live. The
   mock counts created vs destroyed query results and writes the totals to
     ETA_LADYBUG_MOCK_STATE. If the stub leaks the result when the OCaml exception
     unwinds, created stays ahead of destroyed even after a full GC.

   The same mock also exposes a slow query path and records whether
   connection_destroy was called while that query was active. This keeps the
   close/query race regression deterministic without requiring ASAN.

   This binary is isolated from the main connector tests because the mock must
   be the process-wide loaded library (ETA_LADYBUG_LIBRARY), set before any
   ladybug API call triggers the one-shot library load. *)

type mock_state = {
  created : int;
  destroyed : int;
  active_queries : int;
  destroyed_while_active : bool;
}

external fail_next_result_owner_alloc : unit -> unit
  = "eta_ladybug_test_fail_next_result_owner_alloc"

let read_state path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let line = input_line ic in
      match String.split_on_char ' ' (String.trim line) with
      | [ created; destroyed ] ->
          {
            created = int_of_string created;
            destroyed = int_of_string destroyed;
            active_queries = 0;
            destroyed_while_active = false;
          }
      | [ created; destroyed; active_queries; destroyed_while_active ] ->
          {
            created = int_of_string created;
            destroyed = int_of_string destroyed;
            active_queries = int_of_string active_queries;
            destroyed_while_active = int_of_string destroyed_while_active <> 0;
          }
      | _ -> Alcotest.failf "unexpected mock state line: %S" line)

let read_state_opt path =
  try Some (read_state path) with End_of_file | Sys_error _ | Failure _ -> None

let mock_state_path () =
  match Sys.getenv_opt "ETA_LADYBUG_MOCK_STATE" with
  | Some path when path <> "" -> path
  | _ -> Alcotest.fail "ETA_LADYBUG_MOCK_STATE is not configured"

let live_results path =
  match read_state_opt path with
  | None -> 0
  | Some state -> state.created - state.destroyed

let wait_until_active_query path =
  let deadline = Unix.gettimeofday () +. 1.0 in
  let rec loop () =
    if Unix.gettimeofday () > deadline then
      Alcotest.fail "mock query did not become active";
    match read_state_opt path with
    | Some state when state.active_queries > 0 -> ()
    | Some _ | None ->
      Domain.cpu_relax ();
      loop ()
  in
  loop ()

let test_query_result_not_leaked_on_materialize_failure () =
  let open Eta_ladybug in
  (match available () with
  | Ok () -> ()
  | Error err -> Alcotest.failf "mock ladybug library unavailable: %a" pp_error err);
  let state_path = mock_state_path () in
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
  let state = read_state state_path in
  Alcotest.(check bool) "at least one query result was created" true
    (state.created >= 1);
  Alcotest.(check int) "every created query result was destroyed (no leak)"
    state.created state.destroyed

let test_query_result_not_leaked_on_owner_alloc_oom () =
  let open Eta_ladybug in
  (match available () with
  | Ok () -> ()
  | Error err -> Alcotest.failf "mock ladybug library unavailable: %a" pp_error err);
  let state_path = mock_state_path () in
  let live_before = live_results state_path in
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
  fail_next_result_owner_alloc ();
  Alcotest.check_raises "owner allocation OOM" Out_of_memory (fun () ->
      ignore (Connection.query_string conn "RETURN 1" : (string, error) result));
  Gc.full_major ();
  Gc.full_major ();
  Alcotest.(check int)
    "native query results live after owner allocation OOM" live_before
    (live_results state_path)

let test_connection_close_waits_for_active_query () =
  let open Eta_ladybug in
  (match available () with
  | Ok () -> ()
  | Error err -> Alcotest.failf "mock ladybug library unavailable: %a" pp_error err);
  let state_path = mock_state_path () in
  if Sys.file_exists state_path then Sys.remove state_path;
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
  let query_done = Atomic.make false in
  let query_domain =
    (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
      (fun () ->
        ignore
          (Connection.query_string conn "eta_test_slow_query" :
            (string, error) result);
        Atomic.set query_done true)
  in
  wait_until_active_query state_path;
  ignore (Connection.close conn : (unit, error) result);
  Domain.join query_domain;
  Alcotest.(check bool) "query domain completed" true (Atomic.get query_done);
  let state = read_state state_path in
  Alcotest.(check bool)
    "connection_destroy was not called while query was active" false
    state.destroyed_while_active

let pp_timed_error ppf = function
  | Eta_ladybug.Connection.Ladybug err -> Eta_ladybug.pp_error ppf err
  | Eta_ladybug.Connection.Timeout -> Format.pp_print_string ppf "timeout"

let test_query_timeout_bounds_caller_wait () =
  let open Eta_ladybug in
  (match available () with
  | Ok () -> ()
  | Error err -> Alcotest.failf "mock ladybug library unavailable: %a" pp_error err);
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
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let started = Unix.gettimeofday () in
  let exit =
    Eta.Runtime.run rt
      (Connection.query_string_with_timeout ~timeout:(Eta.Duration.ms 10) conn
         "eta_test_slow_query")
  in
  let elapsed_ms = int_of_float ((Unix.gettimeofday () -. started) *. 1000.0) in
  Alcotest.(check bool)
    "timeout should bound caller wait, not wait for slow native query" true
    (elapsed_ms < 100);
  match exit with
  | Eta.Exit.Error (Eta.Cause.Fail Connection.Timeout) -> ()
  | Eta.Exit.Error cause ->
      Alcotest.failf "expected Ladybug Timeout, got %a"
        (Eta.Cause.pp pp_timed_error) cause
  | Eta.Exit.Ok _ -> Alcotest.fail "expected Ladybug Timeout"

let () =
  Alcotest.run "eta_ladybug_leak"
    [
      ( "stub-cleanup",
        [
          Alcotest.test_case "query result not leaked on materialize failure"
            `Quick test_query_result_not_leaked_on_materialize_failure;
          Alcotest.test_case "query result not leaked on owner alloc OOM"
            `Quick test_query_result_not_leaked_on_owner_alloc_oom;
          Alcotest.test_case "connection close waits for active query" `Quick
            test_connection_close_waits_for_active_query;
          Alcotest.test_case "query timeout bounds caller wait" `Quick
            test_query_timeout_bounds_caller_wait;
        ] );
    ]
