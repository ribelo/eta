external unsetenv : string -> unit = "eta_test_unsetenv"

let read_file path =
  let input = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let rec find_sub_from haystack ~needle index =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if index + needle_len > haystack_len then None
  else if String.sub haystack index needle_len = needle then Some index
  else find_sub_from haystack ~needle (index + 1)

let find_sub haystack ~needle = find_sub_from haystack ~needle 0

let require_sub source ~needle =
  match find_sub source ~needle with
  | Some index -> index
  | None -> Alcotest.failf "missing source marker: %s" needle

let find_source label candidates =
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "could not locate %s from %s" label (Sys.getcwd ())

let find_duckdb_stubs_source () =
  find_source "duckdb_stubs.c"
    [
      "lib/duckdb/duckdb_stubs.c";
      "../lib/duckdb/duckdb_stubs.c";
      "../../lib/duckdb/duckdb_stubs.c";
      "../../../lib/duckdb/duckdb_stubs.c";
    ]

let find_ladybug_stubs_source () =
  find_source "ladybug_stubs.c"
    [
      "lib/ladybug/ladybug_stubs.c";
      "../lib/ladybug/ladybug_stubs.c";
      "../../lib/ladybug/ladybug_stubs.c";
      "../../../lib/ladybug/ladybug_stubs.c";
    ]

let find_turso_stubs_source () =
  find_source "turso_stubs.c"
    [
      "lib/turso/turso_stubs.c";
      "../lib/turso/turso_stubs.c";
      "../../lib/turso/turso_stubs.c";
      "../../../lib/turso/turso_stubs.c";
    ]

let find_sqlite_stubs_source () =
  find_source "sqlite_stubs.c"
    [
      "lib/sql/sqlite_stubs.c";
      "../lib/sql/sqlite_stubs.c";
      "../../lib/sql/sqlite_stubs.c";
      "../../../lib/sql/sqlite_stubs.c";
    ]

let function_source source ~start_marker ~end_marker =
  let start = require_sub source ~needle:start_marker in
  match find_sub_from source ~needle:end_marker start with
  | Some finish -> String.sub source start (finish - start)
  | None -> Alcotest.failf "missing end marker after %s: %s" start_marker end_marker

let check_duckdb_bind_params_roots_list_cursor () =
  let source = read_file (find_duckdb_stubs_source ()) in
  let body =
    function_source source ~start_marker:"static int bind_params("
      ~end_marker:"CAMLprim value eta_duckdb_query"
  in
  let root = require_sub body ~needle:"CAMLparam1(params)" in
  let bind = require_sub body ~needle:"bind_value(stmt, index" in
  Alcotest.(check bool) "params root is registered before binding" true (root < bind);
  ignore (require_sub body ~needle:"CAMLreturnT(int, rc)" : int);
  ignore (require_sub body ~needle:"CAMLreturnT(int, 0)" : int);
  match find_sub body ~needle:"return " with
  | None -> ()
  | Some _ -> Alcotest.fail "bind_params must leave through CAMLreturnT"

let check_ladybug_arrow_materialization_uses_release_owner () =
  let source = read_file (find_ladybug_stubs_source ()) in
  let body =
    function_source source ~start_marker:"static value materialize_arrow_rows("
      ~end_marker:"static value execute_direct("
  in
  let owner = require_sub body ~needle:"arrow_owner_alloc" in
  let schema =
    require_sub body ~needle:"api.query_result_get_arrow_schema(result, &owner->schema)"
  in
  let set_schema = require_sub body ~needle:"arrow_owner_set_schema(owner)" in
  let set_array = require_sub body ~needle:"arrow_owner_set_array(owner)" in
  let release_array = require_sub body ~needle:"arrow_owner_release_array(owner)" in
  let release_schema = require_sub body ~needle:"arrow_owner_release_schema(owner)" in
  Alcotest.(check bool) "owner allocated before schema acquisition" true
    (owner < schema);
  Alcotest.(check bool) "schema is marked owned after acquisition" true
    (schema < set_schema);
  Alcotest.(check bool) "array ownership is registered before release path" true
    (set_array < release_array);
  Alcotest.(check bool) "schema release remains on normal path" true
    (release_array < release_schema)

let check_duckdb_materialization_reuses_column_names () =
  let source = read_file (find_duckdb_stubs_source ()) in
  let body =
    function_source source ~start_marker:"static value materialize_rows("
      ~end_marker:"typedef struct duckdb_input_copy"
  in
  ignore (require_sub source ~needle:"static value duckdb_column_names" : int);
  ignore
    (require_sub body ~needle:"field_names = duckdb_column_names(result, cols)" : int);
  ignore (require_sub body ~needle:"Field(field_names, (mlsize_t)col_idx)" : int)

let check_ladybug_arrow_materialization_reuses_column_names () =
  let source = read_file (find_ladybug_stubs_source ()) in
  let body =
    function_source source ~start_marker:"static value materialize_arrow_rows("
      ~end_marker:"static value execute_direct("
  in
  ignore (require_sub source ~needle:"static value arrow_field_names" : int);
  ignore
    (require_sub body ~needle:"field_names = arrow_field_names(&owner->schema)" : int);
  ignore (require_sub body ~needle:"Field(field_names, (mlsize_t)col_idx)" : int)

let check_ladybug_direct_queries_check_strdup () =
  let source = read_file (find_ladybug_stubs_source ()) in
  let check_function start_marker end_marker =
    let body = function_source source ~start_marker ~end_marker in
    let copy = require_sub body ~needle:"cypher_copy = caml_stat_strdup(cypher)" in
    let guard = require_sub body ~needle:"if (cypher_copy == NULL)" in
    let query = require_sub body ~needle:"api.connection_query(conn, cypher_copy" in
    Alcotest.(check bool) "strdup guard precedes query" true
      (copy < guard && guard < query)
  in
  check_function "static value execute_direct(" "static value execute_prepared(";
  check_function "static value execute_direct_values("
    "static value execute_prepared_values("

let check_turso_prepare_copies_sql_and_blocks () =
  let source = read_file (find_turso_stubs_source ()) in
  let body =
    function_source source ~start_marker:"CAMLprim value eta_turso_prepare("
      ~end_marker:"CAMLprim intnat eta_turso_finalize("
  in
  let copy = require_sub body ~needle:"sql = caml_stat_strdup(String_val(v_sql))" in
  let guard = require_sub body ~needle:"if (sql == NULL)" in
  let enter = require_sub body ~needle:"caml_enter_blocking_section()" in
  let prepare = require_sub body ~needle:"api.prepare_v2(db, sql" in
  let leave = require_sub body ~needle:"caml_leave_blocking_section()" in
  let free = require_sub body ~needle:"caml_stat_free(sql)" in
  Alcotest.(check bool) "copy guard precedes prepare" true
    (copy < guard && guard < prepare);
  Alcotest.(check bool) "prepare runs inside blocking section" true
    (enter < prepare && prepare < leave);
  Alcotest.(check bool) "copied SQL is freed after prepare" true (leave < free)

let check_sqlite_and_turso_column_pointers_are_guarded () =
  let sqlite_source = read_file (find_sqlite_stubs_source ()) in
  let turso_source = read_file (find_turso_stubs_source ()) in
  let check_guard source ~start_marker ~end_marker ~pointer =
    let body = function_source source ~start_marker ~end_marker in
    ignore
      (require_sub body
         ~needle:("if (len > 0 && " ^ pointer ^ " == NULL)") :
        int)
  in
  check_guard sqlite_source ~start_marker:"CAMLprim value eta_sqlite_column_text("
    ~end_marker:"CAMLprim value eta_sqlite_column_text_bc(" ~pointer:"text";
  check_guard sqlite_source ~start_marker:"CAMLprim value eta_sqlite_column_blob("
    ~end_marker:"CAMLprim value eta_sqlite_column_blob_bc(" ~pointer:"blob";
  check_guard turso_source ~start_marker:"CAMLprim value eta_turso_column_text("
    ~end_marker:"CAMLprim value eta_turso_column_text_bc(" ~pointer:"text";
  check_guard turso_source ~start_marker:"CAMLprim value eta_turso_column_blob("
    ~end_marker:"CAMLprim value eta_turso_column_blob_bc(" ~pointer:"blob"

let check_duckdb_available () =
  match Eta_duckdb.available () with
  | Ok () -> ()
  | Error err ->
      Alcotest.failf "DuckDB fallback library was not loaded: %a"
        Eta_duckdb.pp_error err

let check_ladybug_available () =
  match Eta_ladybug.available () with
  | Ok () -> ()
  | Error err ->
      Alcotest.failf "Ladybug fallback library was not loaded: %a"
        Eta_ladybug.pp_error err

let fresh_string value = Bytes.to_string (Bytes.of_string value)

let check_ladybug_prepared_query_does_not_expose_ocaml_strings () =
  let cypher = fresh_string "RETURN $name" in
  let param_name = fresh_string "name" in
  let param_value = fresh_string "Ada" in
  let db = Eta_ladybug.Database.open_memory () |> function
    | Ok db -> db
    | Error err -> Alcotest.failf "%a" Eta_ladybug.pp_error err
  in
  Fun.protect
    ~finally:(fun () -> ignore (Eta_ladybug.Database.close db))
    (fun () ->
      let conn =
        match Eta_ladybug.Connection.connect db with
        | Ok conn -> conn
        | Error err -> Alcotest.failf "%a" Eta_ladybug.pp_error err
      in
      Fun.protect
        ~finally:(fun () -> ignore (Eta_ladybug.Connection.close conn))
        (fun () ->
          let result =
            Eta_ladybug.Connection.query_string conn cypher
              ~params:[ Eta_ladybug.Param.string param_name param_value ]
          in
          Alcotest.(check (result string reject)) "query result"
            (Ok "fake prepared") result;
          Alcotest.(check string) "cypher unchanged" "RETURN $name" cypher;
          Alcotest.(check string) "param name unchanged" "name" param_name;
          Alcotest.(check string) "param value unchanged" "Ada" param_value))

let check_turso_available () =
  match Eta_turso.available () with
  | Ok () -> ()
  | Error err ->
      Alcotest.failf "Turso fallback library was not loaded: %a"
        Eta_turso.pp_error err

let duckdb_ok = function
  | Ok value -> value
  | Error err -> Alcotest.failf "%a" Eta_duckdb.pp_error err

let with_duckdb_conn f =
  let db = Eta_duckdb.Database.open_memory () |> duckdb_ok in
  Fun.protect
    ~finally:(fun () -> ignore (Eta_duckdb.Database.close db))
    (fun () ->
      let conn = Eta_duckdb.Connection.connect db |> duckdb_ok in
      Fun.protect
        ~finally:(fun () -> ignore (Eta_duckdb.Connection.close conn))
        (fun () -> f conn))

let check_duckdb_prepared_query_does_not_expose_ocaml_buffers () =
  let sql = fresh_string "INSERT INTO input VALUES (?, ?)" in
  let text = fresh_string "Ada" in
  let blob = Bytes.of_string "blob" in
  with_duckdb_conn (fun conn ->
      let changed =
        Eta_duckdb.Connection.execute conn sql
          [ Eta_duckdb.Value.String text; Bytes blob ]
        |> duckdb_ok
      in
      Alcotest.(check int) "changed rows" 0 changed;
      Alcotest.(check string) "sql unchanged" "INSERT INTO input VALUES (?, ?)" sql;
      Alcotest.(check string) "text unchanged" "Ada" text;
      Alcotest.(check string) "blob unchanged" "blob" (Bytes.to_string blob))

let check_duckdb_appender_does_not_expose_ocaml_buffers () =
  let schema = fresh_string "main" in
  let table = fresh_string "input" in
  let text = fresh_string "Ada" in
  let blob = Bytes.of_string "blob" in
  with_duckdb_conn (fun conn ->
      let appender = Eta_duckdb.Appender.create ~schema conn ~table |> duckdb_ok in
      Fun.protect
        ~finally:(fun () -> ignore (Eta_duckdb.Appender.close appender))
        (fun () ->
          Eta_duckdb.Appender.append_row appender
            [ Eta_duckdb.Value.String text; Bytes blob ]
          |> duckdb_ok;
          Alcotest.(check string) "schema unchanged" "main" schema;
          Alcotest.(check string) "table unchanged" "input" table;
          Alcotest.(check string) "text unchanged" "Ada" text;
          Alcotest.(check string) "blob unchanged" "blob" (Bytes.to_string blob)))

let check_duckdb_blob_result_survives_driver_free_gc () =
  with_duckdb_conn (fun conn ->
      let rows = Eta_duckdb.Connection.query conn "SELECT payload" [] |> duckdb_ok in
      Gc.full_major ();
      Gc.compact ();
      Alcotest.(check int) "row count" 128 (List.length rows);
      rows
      |> List.iteri (fun index row ->
             let expected = Printf.sprintf "blob-row-%03d" index in
             match Eta_duckdb.Row.bytes "payload" row with
             | Some bytes ->
                 Alcotest.(check string)
                   ("payload " ^ string_of_int index)
                   expected (Bytes.to_string bytes)
             | None -> Alcotest.failf "missing blob payload at row %d" index))

let () =
  List.iter unsetenv
    [ "ETA_DUCKDB_LIBRARY"; "ETA_LADYBUG_LIBRARY"; "ETA_TURSO_LIBRARY" ];
  Alcotest.run "connector loader fallback"
    [
      ( "fallback-soname",
        [
          Alcotest.test_case "DuckDB env unset" `Quick check_duckdb_available;
          Alcotest.test_case "Ladybug env unset" `Quick check_ladybug_available;
          Alcotest.test_case "Ladybug prepared query copies strings" `Quick
            check_ladybug_prepared_query_does_not_expose_ocaml_strings;
          Alcotest.test_case "Turso env unset" `Quick check_turso_available;
          Alcotest.test_case "DuckDB prepared query copies buffers" `Quick
            check_duckdb_prepared_query_does_not_expose_ocaml_buffers;
          Alcotest.test_case "DuckDB appender copies buffers" `Quick
            check_duckdb_appender_does_not_expose_ocaml_buffers;
          Alcotest.test_case "DuckDB blob survives driver free GC" `Quick
            check_duckdb_blob_result_survives_driver_free_gc;
          Alcotest.test_case "DuckDB bind params root list cursor" `Quick
            check_duckdb_bind_params_roots_list_cursor;
          Alcotest.test_case "Ladybug Arrow materialization owns releases" `Quick
            check_ladybug_arrow_materialization_uses_release_owner;
          Alcotest.test_case "DuckDB materialization reuses column names" `Quick
            check_duckdb_materialization_reuses_column_names;
          Alcotest.test_case "Ladybug materialization reuses column names" `Quick
            check_ladybug_arrow_materialization_reuses_column_names;
          Alcotest.test_case "Ladybug direct queries check strdup" `Quick
            check_ladybug_direct_queries_check_strdup;
          Alcotest.test_case "Turso prepare copies SQL and blocks" `Quick
            check_turso_prepare_copies_sql_and_blocks;
          Alcotest.test_case "SQLite and Turso column pointers are guarded" `Quick
            check_sqlite_and_turso_column_pointers_are_guarded;
        ] );
    ]
