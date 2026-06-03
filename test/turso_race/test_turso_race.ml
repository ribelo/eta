type mock_state = {
  active_steps : int;
  close_while_active : bool;
}

let read_state path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let line = input_line ic in
      match String.split_on_char ' ' (String.trim line) with
      | [ active_steps; close_while_active ] ->
          {
            active_steps = int_of_string active_steps;
            close_while_active = int_of_string close_while_active <> 0;
          }
      | _ -> Alcotest.failf "unexpected mock state line: %S" line)

let read_state_opt path =
  try Some (read_state path) with End_of_file | Sys_error _ | Failure _ -> None

let mock_state_path () =
  match Sys.getenv_opt "ETA_TURSO_MOCK_STATE" with
  | Some path when path <> "" -> path
  | _ -> Alcotest.fail "ETA_TURSO_MOCK_STATE is not configured"

let wait_until_active_step path =
  let deadline = Unix.gettimeofday () +. 1.0 in
  let rec loop () =
    if Unix.gettimeofday () > deadline then
      Alcotest.fail "mock step did not become active";
    match read_state_opt path with
    | Some state when state.active_steps > 0 -> ()
    | Some _ | None ->
        Domain.cpu_relax ();
        loop ()
  in
  loop ()

let turso_ok = function
  | Ok value -> value
  | Error err -> Alcotest.failf "%a" Eta_turso.pp_error err

let test_close_does_not_destroy_db_while_step_is_active () =
  (match Eta_turso.available () with
  | Ok () -> ()
  | Error err -> Alcotest.failf "mock turso unavailable: %a" Eta_turso.pp_error err);
  let state_path = mock_state_path () in
  if Sys.file_exists state_path then Sys.remove state_path;
  let db = Eta_turso.default_config ":memory:" |> Eta_turso.open_ |> turso_ok in
  let query_done = Atomic.make false in
  let query_domain =
    (Domain.spawn [@alert "-do_not_spawn_domains"] [@alert "-unsafe_multidomain"])
      (fun () ->
        ignore
          (Eta_turso.query db "SELECT eta_test_slow_step()" [] :
            (Eta_turso.Row.t list, Eta_turso.error) result);
        Atomic.set query_done true)
  in
  wait_until_active_step state_path;
  ignore (Eta_turso.close db : (unit, Eta_turso.error) result);
  Domain.join query_domain;
  Alcotest.(check bool) "query domain completed" true (Atomic.get query_done);
  let state = read_state state_path in
  Alcotest.(check bool)
    "sqlite3_close_v2 was not called while sqlite3_step was active" false
    state.close_while_active

let () =
  Alcotest.run "eta_turso_race"
    [
      ( "stub-lifecycle",
        [
          Alcotest.test_case "close does not destroy active step" `Quick
            test_close_does_not_destroy_db_while_step_is_active;
        ] );
    ]
