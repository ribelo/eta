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

let find_duckdb_stubs_source () =
  let candidates =
    [
      "lib/duckdb/duckdb_stubs.c";
      "../lib/duckdb/duckdb_stubs.c";
      "../../lib/duckdb/duckdb_stubs.c";
      "../../../lib/duckdb/duckdb_stubs.c";
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "could not locate duckdb_stubs.c from %s" (Sys.getcwd ())

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
        ] );
    ]
