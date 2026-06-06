module Duckdb_items = struct
  module T = Eta_duckdb.Table.Make (struct
    let name = "items"
  end)

  include T

  let id = column "id" Eta_duckdb.int64
  let name = column "name" Eta_duckdb.text
  let active = column "active" Eta_duckdb.bool
  let score = column "score" Eta_duckdb.float
end

module Turso_items = struct
  module T = Eta_turso.Table.Make (struct
    let name = "items"
  end)

  include T

  let id = column "id" Eta_turso.int64
  let name = column "name" Eta_turso.text
  let active = column "active" Eta_turso.bool
end

module Duckdb_decode_mismatch = struct
  module T = Eta_duckdb.Table.Make (struct
    let name = "decode_mismatch"
  end)

  include T

  let id = column "id" Eta_duckdb.int64
end

module Turso_decode_mismatch = struct
  module T = Eta_turso.Table.Make (struct
    let name = "decode_mismatch"
  end)

  include T

  let id = column "id" Eta_turso.int64
end

let duckdb_ok = function
  | Ok value -> value
  | Error err -> Alcotest.failf "%a" Eta_duckdb.pp_error err

let turso_ok = function
  | Ok value -> value
  | Error err -> Alcotest.failf "%a" Eta_turso.pp_error err

let ladybug_ok = function
  | Ok value -> value
  | Error err -> Alcotest.failf "%a" Eta_ladybug.pp_error err

let env_configured name =
  match Sys.getenv_opt name with
  | Some value -> not (String.equal value "")
  | None -> false

let contains_substring haystack needle =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    index + needle_len <= haystack_len
    &&
    (String.equal (String.sub haystack index needle_len) needle
     || loop (index + 1))
  in
  needle_len = 0 || loop 0

let check_decode_message ?(actual = "got string") label message =
  Alcotest.(check bool)
    (label ^ " has column")
    true
    (contains_substring message "column 0");
  Alcotest.(check bool)
    (label ^ " has expected")
    true
    (contains_substring message "expected int64");
  Alcotest.(check bool)
    (label ^ " has actual")
    true
    (contains_substring message actual);
  Alcotest.(check bool)
    (label ^ " has value")
    true
    (contains_substring message "not-int")

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Sys.rmdir path)
    else Sys.remove path

let require_turso_available () =
  match Eta_turso.available () with
  | Ok () -> true
  | Error (Eta_turso.Library_unavailable message) ->
      if env_configured "ETA_TURSO_LIBRARY" then
        Alcotest.failf "ETA_TURSO_LIBRARY is configured but unavailable: %s" message;
      false
  | Error err -> Alcotest.failf "%a" Eta_turso.pp_error err

let require_ladybug_available () =
  match Eta_ladybug.available () with
  | Ok () -> true
  | Error (Eta_ladybug.Library_unavailable message) ->
      if env_configured "ETA_LADYBUG_LIBRARY" then
        Alcotest.failf "ETA_LADYBUG_LIBRARY is configured but unavailable: %s" message;
      false
  | Error err -> Alcotest.failf "%a" Eta_ladybug.pp_error err

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
              Eta_duckdb.Eta_schema.(
                create_table Duckdb_items.table
                  [
                    column ~primary_key:true Duckdb_items.id;
                    column ~not_null:true Duckdb_items.name;
                    column ~not_null:true Duckdb_items.active;
                    column ~not_null:true Duckdb_items.score;
                  ]
                |> compile)
              |> Eta_duckdb.Connection.run_schema conn
              |> duckdb_ok;
              Eta_duckdb.Bulk.with_appender conn Duckdb_items.table (fun appender ->
                  Eta_duckdb.Bulk_row.(
                    empty
                    |> value Duckdb_items.id 1L
                    |> value Duckdb_items.name "Ada"
                  |> value Duckdb_items.active true
                  |> value Duckdb_items.score 1.5)
                  |> Eta_duckdb.Bulk.append_row appender
                  |> fun result ->
                  Result.bind result (fun () ->
                         Eta_duckdb.Bulk_row.(
                           empty
                           |> value Duckdb_items.id 2L
                           |> value Duckdb_items.name "Grace"
                           |> value Duckdb_items.active true
                           |> value Duckdb_items.score 2.5)
                         |> Eta_duckdb.Bulk.append_row appender)
                  |> fun result ->
                  Result.bind result (fun () ->
                         Eta_duckdb.Bulk_row.(
                           empty
                           |> value Duckdb_items.id 3L
                           |> value Duckdb_items.name "Inactive"
                           |> value Duckdb_items.active false
                           |> value Duckdb_items.score 9.0)
                         |> Eta_duckdb.Bulk.append_row appender))
              |> duckdb_ok;
              let active_rows =
                Eta_duckdb.Select.(
                  from Duckdb_items.table
                    Eta_duckdb.Projection.(t3 (one Duckdb_items.id) (one Duckdb_items.name) (one Duckdb_items.score))
                  |> where Eta_duckdb.Expr.(eq Duckdb_items.active true)
                  |> order_by Duckdb_items.id
                  |> compile)
                |> Eta_duckdb.Connection.select conn
                |> duckdb_ok
              in
              Alcotest.(check (list (triple int64 string (float 0.0001))))
                "active rows"
                [ (1L, "Ada", 1.5); (2L, "Grace", 2.5) ]
                active_rows;
              let changed =
                Eta_duckdb.Update.(
                  table Duckdb_items.table
                  |> set Duckdb_items.score 3.5
                  |> where Eta_duckdb.Expr.(eq Duckdb_items.name "Ada")
                  |> compile)
                |> Eta_duckdb.Connection.execute_compiled conn
                |> duckdb_ok
              in
              ignore changed;
              let ada_score =
                Eta_duckdb.Select.(
                  from Duckdb_items.table Eta_duckdb.Projection.(one Duckdb_items.score)
                  |> where Eta_duckdb.Expr.(eq Duckdb_items.name "Ada")
                  |> compile)
                |> Eta_duckdb.Connection.select conn
                |> duckdb_ok
              in
              Alcotest.(check (list (float 0.0001))) "updated score" [ 3.5 ] ada_score;
              let rows =
                Eta_duckdb.Select.(
                  from Duckdb_items.table
                    Eta_duckdb.Projection.(t2 (one Duckdb_items.id) (one Duckdb_items.name))
                  |> where Eta_duckdb.Expr.(eq Duckdb_items.active true)
                  |> order_by Duckdb_items.id
                  |> compile)
                |> Eta_duckdb.Connection.select conn
                |> duckdb_ok
              in
              Alcotest.(check (list (pair string string)))
                "rows"
                [ ("1", "Ada"); ("2", "Grace") ]
                (List.map
                   (fun (id, name) -> (Int64.to_string id, name))
                   rows)))
  | Error (Eta_duckdb.Library_unavailable message) ->
      Alcotest.(check bool) "message is present" true (String.length message > 0)
  | Error err -> Alcotest.failf "%a" Eta_duckdb.pp_error err

let test_duckdb_open_rejects_invalid_threads_as_result () =
  match Eta_duckdb.Database.open_ { path = None; threads = Some 0 } with
  | Error (Eta_duckdb.Invalid_value message) ->
      Alcotest.(check bool)
        "message mentions threads" true
        (contains_substring message "threads")
  | Error err -> Alcotest.failf "expected Invalid_value, got %a" Eta_duckdb.pp_error err
  | Ok db ->
      ignore (Eta_duckdb.Database.close db);
      Alcotest.fail "invalid threads unexpectedly opened a database"

let test_duckdb_decode_error_is_structured () =
  match Eta_duckdb.available () with
  | Error (Eta_duckdb.Library_unavailable _) -> ()
  | Error err -> Alcotest.failf "%a" Eta_duckdb.pp_error err
  | Ok () ->
      let db = Eta_duckdb.Database.open_memory () |> duckdb_ok in
      Fun.protect
        ~finally:(fun () -> ignore (Eta_duckdb.Database.close db))
        (fun () ->
          let conn = Eta_duckdb.Connection.connect db |> duckdb_ok in
          Fun.protect
            ~finally:(fun () -> ignore (Eta_duckdb.Connection.close conn))
            (fun () ->
              Eta_duckdb.Connection.exec_script conn
                "CREATE TABLE decode_mismatch (id VARCHAR); INSERT INTO decode_mismatch VALUES ('not-int')"
              |> duckdb_ok;
              let query =
                Eta_duckdb.Select.(
                  from Duckdb_decode_mismatch.table
                    Eta_duckdb.Projection.(one Duckdb_decode_mismatch.id)
                  |> compile)
              in
              match Eta_duckdb.Connection.select conn query with
              | Error (Eta_duckdb.Decode_error { message; _ }) ->
                  check_decode_message "duckdb decode" message
              | Error err -> Alcotest.failf "%a" Eta_duckdb.pp_error err
              | Ok _ -> Alcotest.fail "decode mismatch unexpectedly succeeded"))

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

let test_turso_typed_queries () =
  let schema =
    Eta_turso.Eta_schema.(
      create_table Turso_items.table
        [
          column ~primary_key:true Turso_items.id;
          column ~not_null:true Turso_items.name;
          column ~not_null:true Turso_items.active;
        ]
      |> compile)
  in
  let insert =
    Eta_turso.Insert.(
      into Turso_items.table
      |> value Turso_items.id 1L
      |> value Turso_items.name "Ada"
      |> value Turso_items.active true
      |> compile)
  in
  let select =
    Eta_turso.Select.(
      from Turso_items.table Eta_turso.Projection.(t2 (one Turso_items.id) (one Turso_items.name))
      |> where Eta_turso.Expr.(eq Turso_items.active true)
      |> order_by Turso_items.id
      |> compile)
  in
  Alcotest.(check int) "insert params" 3
    (List.length (Eta_turso.Compiled.change_params insert));
  Alcotest.(check int) "select params" 1
    (List.length (Eta_turso.Compiled.select_params select));
  if require_turso_available () then
      let db =
        Eta_turso.default_config ":memory:"
        |> Eta_turso.open_
        |> turso_ok
      in
      Fun.protect
        ~finally:(fun () -> ignore (Eta_turso.close db))
        (fun () ->
          Eta_turso.run_schema db schema |> turso_ok;
          ignore (Eta_turso.execute_compiled db insert |> turso_ok);
          let rows = Eta_turso.select db select |> turso_ok in
          Alcotest.(check (list (pair int64 string)))
            "typed rows" [ (1L, "Ada") ] rows;
          let updated =
            Eta_turso.Update.(
              table Turso_items.table
              |> set Turso_items.active false
              |> where Eta_turso.Expr.(eq Turso_items.name "Ada")
              |> compile)
            |> Eta_turso.execute_compiled db
            |> turso_ok
          in
          Alcotest.(check int) "updated rows" 1 updated;
          let inactive =
            Eta_turso.Select.(
              from Turso_items.table Eta_turso.Projection.(one Turso_items.name)
              |> where Eta_turso.Expr.(eq Turso_items.active false)
              |> compile)
            |> Eta_turso.select db
            |> turso_ok
          in
          Alcotest.(check (list string)) "inactive rows" [ "Ada" ] inactive;
          let deleted =
            Eta_turso.Delete.(
              from Turso_items.table
              |> where Eta_turso.Expr.(eq Turso_items.id 1L)
              |> compile)
            |> Eta_turso.execute_compiled db
            |> turso_ok
          in
          Alcotest.(check int) "deleted rows" 1 deleted;
          let inserted =
            Eta_turso.transaction db (fun db ->
                Eta_turso.Insert.(
                  into Turso_items.table
                  |> value Turso_items.id 2L
                  |> value Turso_items.name "Grace"
                  |> value Turso_items.active true
                  |> compile)
                |> Eta_turso.execute_compiled db)
            |> turso_ok
          in
          Alcotest.(check int) "transaction insert" 1 inserted)

let test_turso_decode_error_is_structured () =
  if require_turso_available () then
    let db = Eta_turso.default_config ":memory:" |> Eta_turso.open_ |> turso_ok in
    Fun.protect
      ~finally:(fun () -> ignore (Eta_turso.close db))
      (fun () ->
        Eta_turso.exec_script db "CREATE TABLE decode_mismatch (id BLOB)"
        |> turso_ok;
        ignore
          (Eta_turso.execute db
             "INSERT INTO decode_mismatch VALUES (X'6e6f742d696e74')"
             []
           |> turso_ok);
        let query =
          Eta_turso.Select.(
            from Turso_decode_mismatch.table
              Eta_turso.Projection.(one Turso_decode_mismatch.id)
            |> compile)
        in
        match Eta_turso.select db query with
        | Error (Eta_turso.Decode_error { message; _ }) ->
            check_decode_message ~actual:"got bytes" "turso decode" message
        | Error err -> Alcotest.failf "%a" Eta_turso.pp_error err
        | Ok _ -> Alcotest.fail "decode mismatch unexpectedly succeeded")

let test_turso_text_preserves_embedded_nul () =
  if require_turso_available () then
    let db = Eta_turso.default_config ":memory:" |> Eta_turso.open_ |> turso_ok in
    Fun.protect
      ~finally:(fun () -> ignore (Eta_turso.close db))
      (fun () ->
        let expected = "left\000right" in
        let rows =
          Eta_turso.query db "SELECT ? AS txt" [ Eta_turso.Value.String expected ]
          |> turso_ok
        in
        match rows with
        | [ [ ("txt", Eta_turso.Value.String actual) ] ] ->
            Alcotest.(check int) "text length" (String.length expected)
              (String.length actual);
            Alcotest.(check bool) "text bytes" true
              (String.equal expected actual)
        | _ -> Alcotest.fail "expected one text column")

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

let test_ladybug_typed_query_builder () =
  let open Eta_ladybug in
  let pattern =
    Pattern.path
      [
        Pattern.node ~as_:"p" ~labels:[ "Person" ] ~props:[ ("name", "name") ] ();
        Pattern.rel ~label:"KNOWS" ();
        Pattern.node ~as_:"friend" ~labels:[ "Person" ] ();
      ]
  in
  let query =
    Query.(
      match_ pattern
      |> with_params [ Param.string "name" "Ada"; Param.int "min_age" 18L ]
      |> where Expr.(gt (property "friend" "age") (param "min_age"))
      |> order_by "friend.name"
      |> limit 5
      |> returning [ "p.name"; "friend.name" ]
           ~decode:Decode.(tuple2 (string "p.name") (string "friend.name")))
  in
  Alcotest.(check string) "cypher"
    "MATCH (p:Person {name: $name})-[:KNOWS]->(friend:Person) WHERE friend.age > $min_age RETURN p.name, friend.name ORDER BY friend.name ASC LIMIT 5"
    (Query.cypher query);
  Alcotest.(check int) "params" 2 (List.length (Query.params query));
  Alcotest.(check (result (pair string string) string)) "decode row"
    (Ok ("Ada", "Grace"))
    (Decode.run (Query.decode query)
       [
         ("p.name", Value.String "Ada");
         ("friend.name", Value.String "Grace");
       ])

let test_ladybug_extension_helpers () =
  let open Eta_ladybug in
  let json = Extension.official "JSON" |> ladybug_ok in
  Alcotest.(check string) "canonical official name" "json"
    (Extension.name json);
  begin match Extension.official "json;load" with
  | Result.Error (Invalid_value _) -> ()
  | Ok _ -> Alcotest.fail "invalid official extension name was accepted"
  | Result.Error err -> Alcotest.failf "%a" pp_error err
  end;
  if require_ladybug_available () then
    let home = Filename.temp_file "eta-ladybug-extensions-" "" in
    Sys.remove home;
    Sys.mkdir home 0o700;
    Fun.protect
      ~finally:(fun () -> remove_tree home)
      (fun () ->
        let db = Database.open_memory () |> ladybug_ok in
        Fun.protect
          ~finally:(fun () -> ignore (Database.close db))
          (fun () ->
            let conn = Connection.connect db |> ladybug_ok in
            Fun.protect
              ~finally:(fun () -> ignore (Connection.close conn))
              (fun () ->
                Connection.exec conn
                  ("CALL home_directory = '" ^ String.escaped home ^ "'")
                |> ladybug_ok;
                let official = Connection.official_extensions conn |> ladybug_ok in
                Alcotest.(check bool) "json is official"
                  true
                  (List.exists
                     (fun (extension : Extension.available) ->
                       String.equal extension.name "JSON")
                     official);
                begin match Connection.load_extension conn Extension.json with
                | Result.Error
                    (Driver_error
                      { operation = "extension load"; _ }) ->
                    ()
                | Ok () -> Alcotest.fail "uninstalled official extension loaded"
                | Result.Error err -> Alcotest.failf "%a" pp_error err
                end;
                let extension_path =
                  match Sys.getenv_opt "ETA_LADYBUG_TEST_EXTENSION" with
                  | Some path ->
                      let path =
                        if Filename.is_relative path then
                          Filename.concat (Sys.getcwd ()) path
                        else path
                      in
                      if Sys.file_exists path then path
                      else Alcotest.fail "ETA_LADYBUG_TEST_EXTENSION does not exist"
                  | None -> Alcotest.fail "ETA_LADYBUG_TEST_EXTENSION is not configured"
                in
                Connection.load_extension_path conn ~path:extension_path |> ladybug_ok;
                let loaded = Connection.loaded_extensions conn |> ladybug_ok in
                let test_extension =
                  List.find_opt
                    (fun (extension : Extension.loaded) ->
                      String.equal extension.name "ETA_TEST")
                    loaded
                in
                begin match test_extension with
                | Some { Extension.source = User; path; _ } ->
                    Alcotest.(check string) "loaded path" extension_path path
                | Some _ -> Alcotest.fail "ETA_TEST was not reported as a user extension"
                | None -> Alcotest.fail "ETA_TEST extension was not reported as loaded"
                end;
                begin
                  match
                    Connection.load_extension_path conn
                      ~path:(extension_path ^ ".missing")
                  with
                  | Result.Error
                      (Driver_error
                        { operation = "extension load"; _ }) ->
                      ()
                  | Ok () -> Alcotest.fail "missing extension path loaded"
                  | Result.Error err -> Alcotest.failf "%a" pp_error err
                end)))

let test_ladybug_official_extension_install_lifecycle () =
  let open Eta_ladybug in
  if
    require_ladybug_available ()
    && env_configured "ETA_LADYBUG_TEST_REMOTE_EXTENSIONS"
  then
    let home = Filename.temp_file "eta-ladybug-extensions-" "" in
    Sys.remove home;
    Sys.mkdir home 0o700;
    Fun.protect
      ~finally:(fun () -> remove_tree home)
      (fun () ->
        let db = Database.open_memory () |> ladybug_ok in
        Fun.protect
          ~finally:(fun () -> ignore (Database.close db))
          (fun () ->
            let conn = Connection.connect db |> ladybug_ok in
            Fun.protect
              ~finally:(fun () -> ignore (Connection.close conn))
              (fun () ->
                Connection.exec conn
                  ("CALL home_directory = '" ^ String.escaped home ^ "'")
                |> ladybug_ok;
                Connection.install_extension conn Extension.json |> ladybug_ok;
                Connection.load_extension conn Extension.json |> ladybug_ok;
                let loaded = Connection.loaded_extensions conn |> ladybug_ok in
                Alcotest.(check bool) "json loaded"
                  true
                  (List.exists
                     (fun (extension : Extension.loaded) ->
                       String.equal extension.name "JSON"
                       && extension.source = Extension.Official)
                     loaded);
                Connection.install_extension conn Extension.json |> ladybug_ok)))

let test_ladybug_typed_query_runtime () =
  let open Eta_ladybug in
  if require_ladybug_available () then
    let db = Database.open_memory () |> ladybug_ok in
    Fun.protect
      ~finally:(fun () -> ignore (Database.close db))
      (fun () ->
        let conn = Connection.connect db |> ladybug_ok in
        Fun.protect
          ~finally:(fun () -> ignore (Connection.close conn))
          (fun () ->
            Connection.exec conn
              "CREATE NODE TABLE Person(id INT64, name STRING, age INT64, active BOOL, PRIMARY KEY(id))"
            |> ladybug_ok;
            Connection.exec conn
              "CREATE (:Person {id: 7, name: 'Ada', age: 42, active: true})"
            |> ladybug_ok;
            let query_by_name name =
              Query.(
                match_
                  (Pattern.node ~as_:"p" ~labels:[ "Person" ]
                     ~props:[ ("name", "name") ] ())
                |> with_params [ Param.string "name" name ]
                |> returning [ "p" ] ~decode:Decode.(node "p"))
            in
            let query = query_by_name "Ada" in
            let nodes = Connection.query conn query |> ladybug_ok in
            begin match nodes with
            | [ node ] ->
                Alcotest.(check (list string)) "node labels" [ "Person" ] node.labels;
                let prop name = List.assoc_opt name node.properties in
                Alcotest.(check (option int64)) "id"
                  (Some 7L)
                  (match prop "id" with Some (Value.Int value) -> Some value | _ -> None);
                Alcotest.(check (option string)) "name"
                  (Some "Ada")
                  (match prop "name" with
                   | Some (Value.String value) -> Some value
                   | _ -> None);
                Alcotest.(check (option int64)) "age"
                  (Some 42L)
                  (match prop "age" with Some (Value.Int value) -> Some value | _ -> None);
                Alcotest.(check (option bool)) "active"
                  (Some true)
                  (match prop "active" with
                   | Some (Value.Bool value) -> Some value
                   | _ -> None)
            | _ -> Alcotest.failf "expected one typed node, got %d" (List.length nodes);
            end;
            Connection.transaction conn (fun conn ->
                Connection.exec conn
                  "CREATE (:Person {id: 8, name: 'Grace', age: 37, active: true})")
            |> ladybug_ok;
            let grace_nodes = Connection.query conn (query_by_name "Grace") |> ladybug_ok in
            Alcotest.(check int) "committed transaction node" 1
              (List.length grace_nodes);
            let rollback_result =
              Connection.transaction conn (fun conn ->
                  match
                    Connection.exec conn
                      "CREATE (:Person {id: 9, name: 'Rollback', age: 1, active: false})"
                  with
                  | Result.Error _ as err -> err
                  | Ok () -> Result.Error (Invalid_value "rollback"))
            in
            begin match rollback_result with
            | Result.Error (Invalid_value "rollback") -> ()
            | Ok () -> Alcotest.fail "rollback transaction unexpectedly committed"
            | Result.Error err -> Alcotest.failf "%a" pp_error err
            end;
            let rolled_back =
              Connection.query conn (query_by_name "Rollback") |> ladybug_ok
            in
            Alcotest.(check int) "rolled back transaction node" 0
              (List.length rolled_back);
            Connection.exec conn
              "CREATE NODE TABLE BatchPerson(id INT64, name STRING, active BOOL, PRIMARY KEY(id))"
            |> ladybug_ok;
            Connection.exec
              ~params:
                [
                  Param.rows "rows"
                    [
                      [
                        ("id", Value.Int 100L);
                        ("name", Value.String "Batch Ada");
                        ("active", Value.Bool true);
                      ];
                      [
                        ("id", Value.Int 101L);
                        ("name", Value.String "Batch Grace");
                        ("active", Value.Bool false);
                      ];
                    ];
                ]
              conn
              "UNWIND $rows AS row CREATE (:BatchPerson {id: row.id, name: row.name, active: row.active})"
            |> ladybug_ok;
            let batch_count =
              Query.raw
                ~cypher:"MATCH (p:BatchPerson) RETURN count(p) AS c"
                ~decode:Decode.(int "c")
                ()
              |> Connection.query conn
              |> ladybug_ok
            in
            Alcotest.(check (list int64)) "batch rows" [ 2L ] batch_count))

let test_ladybug_connection_query_timeout () =
  let open Eta_ladybug in
  if require_ladybug_available () then
    Eio_main.run @@ fun stdenv ->
    Eio.Switch.run @@ fun sw ->
    let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
    let db = Database.open_memory () |> ladybug_ok in
    Fun.protect
      ~finally:(fun () -> ignore (Database.close db))
      (fun () ->
        let conn = Connection.connect db |> ladybug_ok in
        Fun.protect
          ~finally:(fun () -> ignore (Connection.close conn))
          (fun () ->
            Connection.exec conn "CREATE NODE TABLE N(id INT64, PRIMARY KEY(id))"
            |> ladybug_ok;
            Connection.exec conn
              "UNWIND range(1, 20000) AS i CREATE (:N {id: i})"
            |> ladybug_ok;
            let long_query =
              Query.raw
                ~cypher:
                  "MATCH (a:N), (b:N), (c:N) RETURN sum(a.id + b.id + c.id) AS s"
                ~decode:Decode.(int "s")
                ()
            in
            let result =
              Connection.query_with_timeout ~timeout:(Eta.Duration.ms 100) conn
                long_query
              |> Eta.Runtime.run rt
            in
            begin match result with
            | Eta.Exit.Error (Eta.Cause.Fail Connection.Timeout) -> ()
            | Eta.Exit.Error cause ->
                Alcotest.failf "expected timeout, got %a"
                  (Eta.Cause.pp (fun fmt -> function
                    | Connection.Timeout -> Format.pp_print_string fmt "Timeout"
                    | Connection.Ladybug err -> pp_error fmt err))
                  cause
            | Eta.Exit.Ok _ -> Alcotest.fail "expected query timeout"
            end;
            let reusable =
              Query.raw ~cypher:"RETURN 1 AS one" ~decode:Decode.(int "one") ()
              |> Connection.query conn
              |> ladybug_ok
            in
            Alcotest.(check (list int64)) "connection reusable" [ 1L ] reusable))

(* P0: Memory leak of C-allocated statements on bind errors.
   When binding fails (e.g. unsupported List/Struct parameter in DuckDB, or
   unsupported type in LadybugDB), caml_failwith() longjmps out of C without
   finalizing the prepared statement. Each failed bind permanently leaks
   the statement allocation in the database engine.

   This test triggers bind failures in a tight loop and asserts that RSS
   does not grow unboundedly. With the bug present, each iteration leaks
   the prepared statement; 50000 iterations should leak enough to detect. *)

let rss_kb () =
  try
    let ic = open_in "/proc/self/status" in
    Fun.protect ~finally:(fun () -> close_in ic) (fun () ->
        let rec loop () =
          let line = input_line ic in
          if String.length line > 6 && String.sub line 0 6 = "VmRSS:" then
            Scanf.sscanf line "VmRSS: %d kB" Fun.id
          else loop ()
        in
        loop ())
  with _ -> 0

let test_duckdb_bind_error_does_not_leak_prepared_statements () =
  match Eta_duckdb.available () with
  | Error _ -> Alcotest.fail "DuckDB not available"
  | Ok () ->
      let db = duckdb_ok (Eta_duckdb.Database.open_memory ()) in
      Fun.protect
        ~finally:(fun () -> ignore (Eta_duckdb.Database.close db))
        (fun () ->
          let conn = duckdb_ok (Eta_duckdb.Connection.connect db) in
          Fun.protect
            ~finally:(fun () -> ignore (Eta_duckdb.Connection.close conn))
            (fun () ->
              (* Create a table so the prepared statement is non-trivial *)
              duckdb_ok
                (Eta_duckdb.Connection.exec_script conn
                   "CREATE TABLE leak_test (id BIGINT, name VARCHAR)");
              (* Force GC to get a stable baseline *)
              Gc.full_major ();
              Gc.compact ();
              let rss_before = rss_kb () in
              (* Trigger bind failure 50000 times.
                 Each call prepares a statement, then fails during bind
                 (List values are unsupported), longjumping out of C.
                 The prepared statement is never finalized. *)
              let iterations = 50_000 in
              for _ = 1 to iterations do
                match
                  Eta_duckdb.Connection.query conn
                    "SELECT * FROM leak_test WHERE id = ?"
                    [ Eta_duckdb.Value.List [ Eta_duckdb.Value.Int 1 ] ]
                with
                | Error _ -> () (* Expected: bind failure *)
                | Ok _ -> Alcotest.fail "query with List param should fail"
              done;
              Gc.full_major ();
              Gc.compact ();
              let rss_after = rss_kb () in
              (* If statements are leaked, 50000 prepared statements ×
                 ~1-4KB each = 50-200MB growth. Allow 20MB as noise floor
                 for a clean implementation (GC, allocator fragmentation). *)
              let growth_kb = rss_after - rss_before in
              let max_acceptable_kb = 20_000 in (* 20MB *)
              Alcotest.(check bool)
                (Printf.sprintf
                   "RSS growth from bind errors should be bounded \
                    (grew %d KB, limit %d KB)" growth_kb max_acceptable_kb)
                true (growth_kb < max_acceptable_kb)))

let test_duckdb_list_result_is_materialized_as_value_list () =
  match Eta_duckdb.available () with
  | Error _ -> ()
  | Ok () ->
      let db = duckdb_ok (Eta_duckdb.Database.open_memory ()) in
      Fun.protect
        ~finally:(fun () -> ignore (Eta_duckdb.Database.close db))
        (fun () ->
          let conn = duckdb_ok (Eta_duckdb.Connection.connect db) in
          Fun.protect
            ~finally:(fun () -> ignore (Eta_duckdb.Connection.close conn))
            (fun () ->
              match Eta_duckdb.Connection.query conn "SELECT [1, 2, 3] AS xs" [] with
              | Ok
                  [
                    [
                      ( "xs",
                        Eta_duckdb.Value.List
                          [
                            Eta_duckdb.Value.Int 1;
                            Eta_duckdb.Value.Int 2;
                            Eta_duckdb.Value.Int 3;
                          ] );
                    ];
                  ] ->
                  ()
              | Ok rows ->
                  Alcotest.failf
                    "expected DuckDB list result to decode as Value.List, got: %s"
                    (String.concat "; "
                       (List.map
                          (fun row ->
                            String.concat ", "
                              (List.map
                                 (fun (name, value) ->
                                   name ^ "=" ^ Eta_duckdb.Value.to_string value)
                                 row))
                          rows))
              | Error err ->
                  Alcotest.failf "query failed: %s" (Eta_duckdb.show_error err)))

let test_ladybug_bind_error_does_not_leak_prepared_statements () =
  match Eta_ladybug.available () with
  | Error _ -> Alcotest.fail "LadybugDB not available"
  | Ok () ->
      let db = ladybug_ok (Eta_ladybug.Database.open_memory ()) in
      Fun.protect
        ~finally:(fun () -> ignore (Eta_ladybug.Database.close db))
        (fun () ->
          let conn = ladybug_ok (Eta_ladybug.Connection.connect db) in
          Fun.protect
            ~finally:(fun () -> ignore (Eta_ladybug.Connection.close conn))
            (fun () ->
              (* Create a node so the schema exists *)
              ignore (ladybug_ok
                (Eta_ladybug.Connection.query_string conn
                   "CREATE NODE TABLE IF NOT EXISTS leak_node(id INT64, PRIMARY KEY(id))"));
              Gc.full_major ();
              Gc.compact ();
              let rss_before = rss_kb () in
              (* Trigger bind failure with an unsupported nested parameter type.
                 LadybugDB's create_lbug_value calls caml_failwith on Node/Rel/Path
                 values nested inside a list, leaking the prepared statement. *)
              let iterations = 50_000 in
              let bad_param =
                Eta_ladybug.Param.list "id"
                  [ Eta_ladybug.Value.Node
                      { id = None; labels = []; properties = [] } ]
              in
              for _ = 1 to iterations do
                match
                  Eta_ladybug.Connection.query_string conn
                    ~params:[ bad_param ]
                    "MATCH (n:leak_node) WHERE n.id = $id RETURN n.id"
                with
                | Error _ -> () (* Expected: bind failure *)
                | Ok _ -> Alcotest.fail "query with Node param should fail"
              done;
              Gc.full_major ();
              Gc.compact ();
              let rss_after = rss_kb () in
              let growth_kb = rss_after - rss_before in
              let max_acceptable_kb = 20_000 in
              Alcotest.(check bool)
                (Printf.sprintf
                   "RSS growth from bind errors should be bounded \
                    (grew %d KB, limit %d KB)" growth_kb max_acceptable_kb)
                true (growth_kb < max_acceptable_kb)))

(* P1: DuckDB appender close failures must not leak native handles.
   A failed close leaves no supported reset/rollback path. Eta destroys the
   native appender and poisons the OCaml wrapper instead of leaving cleanup to
   the finalizer or pretending a retry is safe. *)

let test_duckdb_appender_failed_close_poisons_handle () =
  match Eta_duckdb.available () with
  | Error _ -> Alcotest.fail "DuckDB not available"
  | Ok () ->
      let db = duckdb_ok (Eta_duckdb.Database.open_memory ()) in
      Fun.protect
        ~finally:(fun () -> ignore (Eta_duckdb.Database.close db))
        (fun () ->
          let conn = duckdb_ok (Eta_duckdb.Connection.connect db) in
          Fun.protect
            ~finally:(fun () -> ignore (Eta_duckdb.Connection.close conn))
            (fun () ->
              (* Create a table with NOT NULL constraints using the typed API *)
              duckdb_ok
                (Eta_duckdb.Eta_schema.(
                   create_table Duckdb_items.table
                     [
                       column ~primary_key:true Duckdb_items.id;
                       column ~not_null:true Duckdb_items.name;
                       column ~not_null:true Duckdb_items.active;
                       column ~not_null:true Duckdb_items.score;
                     ]
                   |> compile)
                 |> Eta_duckdb.Connection.run_schema conn);
              (* Create appender *)
              let appender =
                duckdb_ok (Eta_duckdb.Bulk.create conn Duckdb_items.table)
              in
              (* Append a valid row first *)
              duckdb_ok
                (Eta_duckdb.Bulk.append_row appender
                   Eta_duckdb.Bulk_row.(
                     empty
                     |> value Duckdb_items.id 1L
                     |> value Duckdb_items.name "ok"
                     |> value Duckdb_items.active true
                     |> value Duckdb_items.score 1.0));
              (* Flush to commit the first row, then create a fresh appender
                 to attempt triggering a close failure *)
              duckdb_ok (Eta_duckdb.Bulk.close appender);
              (* Insert a duplicate primary key via SQL to set up a conflict *)
              duckdb_ok
                (Eta_duckdb.Connection.exec_script conn
                   "INSERT INTO items (id, name, active, score) VALUES (2, 'x', true, 0.0)");
              (* Create new appender and try to insert duplicate PK *)
              let appender2 =
                duckdb_ok (Eta_duckdb.Bulk.create conn Duckdb_items.table)
              in
              duckdb_ok
                (Eta_duckdb.Bulk.append_row appender2
                   Eta_duckdb.Bulk_row.(
                     empty
                     |> value Duckdb_items.id 2L  (* duplicate PK *)
                     |> value Duckdb_items.name "dup"
                     |> value Duckdb_items.active true
                     |> value Duckdb_items.score 2.0));
              (* Close may fail due to PK constraint violation. *)
              match Eta_duckdb.Bulk.close appender2 with
              | Ok () ->
                  (* DuckDB appender might not enforce PK on close.
                     In that case the ordering bug isn't observable here. *)
                  ()
              | Error _ ->
                  (* Close failed. The native handle has been destroyed, so the
                     wrapper must be closed rather than retryable. *)
                  (match Eta_duckdb.Bulk.close appender2 with
                  | Error Eta_duckdb.Closed -> ()
                  | Error err ->
                      Alcotest.failf
                        "failed close should poison handle, got %a"
                        Eta_duckdb.pp_error err
                  | Ok () ->
                      Alcotest.fail
                        "failed close should poison handle, got retry success")))

let () =
  Alcotest.run "Eta database connectors"
    [
      ( "duckdb",
        [
          Alcotest.test_case "values and rows" `Quick test_duckdb_values;
          Alcotest.test_case "available is result" `Quick test_duckdb_available_is_result;
          Alcotest.test_case "invalid threads is result" `Quick
            test_duckdb_open_rejects_invalid_threads_as_result;
          Alcotest.test_case "decode errors are structured" `Quick
            test_duckdb_decode_error_is_structured;
          Alcotest.test_case "bind error does not leak statements" `Slow
            test_duckdb_bind_error_does_not_leak_prepared_statements;
          Alcotest.test_case "list result materializes value list" `Quick
            test_duckdb_list_result_is_materialized_as_value_list;
          Alcotest.test_case "appender failed close poisons handle" `Quick
            test_duckdb_appender_failed_close_poisons_handle;
        ] );
      ( "turso",
        [
          Alcotest.test_case "config and retry" `Quick test_turso_config_and_retry;
          Alcotest.test_case "available is result" `Quick test_turso_available_is_result;
          Alcotest.test_case "typed queries" `Quick test_turso_typed_queries;
          Alcotest.test_case "decode errors are structured" `Quick
            test_turso_decode_error_is_structured;
          Alcotest.test_case "text preserves embedded nul" `Quick
            test_turso_text_preserves_embedded_nul;
        ] );
      ( "ladybug",
        [
          Alcotest.test_case "error classification" `Quick
            test_ladybug_error_classification;
          Alcotest.test_case "available is result" `Quick
            test_ladybug_available_is_result;
          Alcotest.test_case "typed query builder" `Quick
            test_ladybug_typed_query_builder;
          Alcotest.test_case "extension helpers" `Quick
            test_ladybug_extension_helpers;
          Alcotest.test_case "official extension install lifecycle" `Slow
            test_ladybug_official_extension_install_lifecycle;
          Alcotest.test_case "typed query runtime" `Quick
            test_ladybug_typed_query_runtime;
          Alcotest.test_case "connection query timeout" `Quick
            test_ladybug_connection_query_timeout;
          Alcotest.test_case "bind error does not leak statements" `Slow
            test_ladybug_bind_error_does_not_leak_prepared_statements;
        ] );
    ]
