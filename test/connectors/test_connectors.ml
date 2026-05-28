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
                    Eta_duckdb.Projection.(t3 Duckdb_items.id Duckdb_items.name Duckdb_items.score)
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
                    Eta_duckdb.Projection.(t2 Duckdb_items.id Duckdb_items.name)
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
      from Turso_items.table Eta_turso.Projection.(t2 Turso_items.id Turso_items.name)
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
              (List.length rolled_back)))

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
          Alcotest.test_case "typed queries" `Quick test_turso_typed_queries;
        ] );
      ( "ladybug",
        [
          Alcotest.test_case "error classification" `Quick
            test_ladybug_error_classification;
          Alcotest.test_case "available is result" `Quick
            test_ladybug_available_is_result;
          Alcotest.test_case "typed query builder" `Quick
            test_ladybug_typed_query_builder;
          Alcotest.test_case "typed query runtime" `Quick
            test_ladybug_typed_query_runtime;
        ] );
    ]
