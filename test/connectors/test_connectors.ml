let test_duckdb_values () =
  let row =
    [
      ("id", Eta_duckdb.Value.Int64 42L);
      ("name", String "Ada");
      ("active", Bool true);
      ("payload", Bytes (Bytes.of_string "abc"));
    ]
  in
  Alcotest.(check (option int)) "id" (Some 42) (Eta_duckdb.Row.int "id" row);
  Alcotest.(check (option string)) "name" (Some "Ada") (Eta_duckdb.Row.string "name" row);
  Alcotest.(check (option bool)) "active" (Some true) (Eta_duckdb.Row.bool "active" row);
  Alcotest.(check (option bytes)) "payload" (Some (Bytes.of_string "abc"))
    (Eta_duckdb.Row.bytes "payload" row)

let test_duckdb_available_is_result () =
  match Eta_duckdb.available () with
  | Ok () ->
      let db =
        match Eta_duckdb.Database.open_memory () with
        | Ok db -> db
        | Error err -> Alcotest.failf "%a" Eta_duckdb.pp_error err
      in
      Fun.protect
        ~finally:(fun () -> ignore (Eta_duckdb.Database.close db))
        (fun () ->
          let conn =
            match Eta_duckdb.Connection.connect db with
            | Ok conn -> conn
            | Error err -> Alcotest.failf "%a" Eta_duckdb.pp_error err
          in
          Fun.protect
            ~finally:(fun () -> ignore (Eta_duckdb.Connection.close conn))
            (fun () ->
              ignore
                (Eta_duckdb.Connection.exec_script conn
                   "CREATE TABLE items(id BIGINT, name VARCHAR)"
                 |> Result.get_ok);
              ignore
                (Eta_duckdb.Connection.execute conn
                   "INSERT INTO items VALUES (?, ?)"
                   [ Eta_duckdb.Value.Int64 1L; Eta_duckdb.Value.String "Ada" ]
                 |> Result.get_ok);
              let rows =
                Eta_duckdb.Connection.query conn
                  "SELECT id, name FROM items"
                  []
                |> Result.get_ok
              in
              Alcotest.(check (list (pair string string)))
                "rows"
                [ ("1", "Ada") ]
                (List.map
                   (fun row ->
                     ( Option.get (Eta_duckdb.Row.int64 "id" row)
                       |> Int64.to_string,
                       Option.get (Eta_duckdb.Row.string "name" row) ))
                   rows)))
  | Error (Eta_duckdb.Library_unavailable message) ->
      Alcotest.(check bool) "message is present" true (String.length message > 0)
  | Error err -> Alcotest.failf "%a" Eta_duckdb.pp_error err

let test_turso_config_and_retry () =
  let config = Eta_turso.default_config "app.db" in
  Alcotest.(check string) "path" "app.db" config.path;
  Alcotest.(check bool) "foreign keys" true config.foreign_keys;
  let attempts = ref 0 in
  let result =
    Eta_turso.retry_on_conflict ~max_attempts:3
      ~backoff:(fun ~attempt -> attempts := max !attempts attempt)
      (fun () -> Error (Eta_turso.Invalid_config "not retryable"))
  in
  Alcotest.(check int) "no retry" 0 !attempts;
  Alcotest.(check bool) "still error" true (Result.is_error result)

let test_turso_available_is_result () =
  match Eta_turso.available () with
  | Ok () -> ()
  | Error (Eta_turso.Library_unavailable message) ->
      Alcotest.(check bool) "message is present" true (String.length message > 0)
  | Error err -> Alcotest.failf "%a" Eta_turso.pp_error err

let test_ladybug_error_classification () =
  let open Eta_ladybug in
  Alcotest.(check bool) "parser"
    true
    (classify_error "Parser exception: bad cypher" = Query_syntax);
  Alcotest.(check bool) "binder"
    true
    (classify_error "Binder exception: bad type" = Type_mismatch);
  Alcotest.(check bool) "constraint"
    true
    (classify_error "Runtime exception: duplicated primary key" = Integrity_violation);
  Alcotest.(check bool) "interrupt"
    true
    (classify_error "Interrupted." = Timeout_or_interrupt)

let test_ladybug_available_is_result () =
  match Eta_ladybug.available () with
  | Ok () -> ()
  | Error (Eta_ladybug.Library_unavailable message) ->
      Alcotest.(check bool) "message is present" true (String.length message > 0)
  | Error err -> Alcotest.failf "%a" Eta_ladybug.pp_error err

let () =
  Alcotest.run "Eta database connectors"
    [
      ( "duckdb",
        [
          Alcotest.test_case "values and rows" `Quick test_duckdb_values;
          Alcotest.test_case "available is result" `Quick test_duckdb_available_is_result;
        ] );
      ( "turso",
        [
          Alcotest.test_case "config and retry" `Quick test_turso_config_and_retry;
          Alcotest.test_case "available is result" `Quick test_turso_available_is_result;
        ] );
      ( "ladybug",
        [
          Alcotest.test_case "error classification" `Quick
            test_ladybug_error_classification;
          Alcotest.test_case "available is result" `Quick
            test_ladybug_available_is_result;
        ] );
    ]
