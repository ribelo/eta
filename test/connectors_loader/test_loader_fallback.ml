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

let require_sub_after source ~needle index =
  match find_sub_from source ~needle index with
  | Some index -> index
  | None -> Alcotest.failf "missing source marker after %d: %s" index needle

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

let check_duckdb_query_result_owner_precedes_native_result () =
  let source = read_file (find_duckdb_stubs_source ()) in
  let body =
    function_source source ~start_marker:"CAMLprim value eta_duckdb_query("
      ~end_marker:"CAMLprim value eta_duckdb_execute("
  in
  let alloc = require_sub body ~needle:"result_owner = result_owner_alloc()" in
  let execute = require_sub body ~needle:"api.execute_prepared(stmt, &result)" in
  let transfer =
    require_sub_after body ~needle:"*result_owner_val(result_owner) = result"
      execute
  in
  let activate = require_sub body ~needle:"result_owner_activate(result_owner)" in
  Alcotest.(check bool) "result owner is allocated before native result" true
    (alloc < execute);
  Alcotest.(check bool) "native result is transferred before activation" true
    (execute < transfer && transfer < activate);
  match find_sub body ~needle:"api.execute_prepared(stmt, result_owner_val" with
  | None -> ()
  | Some _ ->
      Alcotest.fail
        "blocking execute must not touch the OCaml result owner directly"

let check_ladybug_arrow_materialization_uses_release_owner () =
  let source = read_file (find_ladybug_stubs_source ()) in
  let body =
    function_source source ~start_marker:"static value materialize_arrow_rows("
      ~end_marker:"static value execute_direct("
  in
  let owner = require_sub body ~needle:"arrow_owner_alloc" in
  let schema =
    require_sub body
      ~needle:
        "api.query_result_get_arrow_schema(result_owner_result(v_result_owner), &owner->schema)"
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

let check_column_name_arrays_initialize_gc_roots () =
  let check source ~start_marker ~end_marker ~init_marker =
    let body = function_source source ~start_marker ~end_marker in
    let alloc = require_sub body ~needle:"field_names = caml_alloc((mlsize_t)" in
    let init = require_sub body ~needle:init_marker in
    let copy = require_sub body ~needle:"field_name = caml_copy_string" in
    Alcotest.(check bool)
      "tuple fields are initialized before allocating strings" true
      (alloc < init && init < copy)
  in
  check (read_file (find_duckdb_stubs_source ()))
    ~start_marker:"static value duckdb_column_names("
    ~end_marker:"static value materialize_rows("
    ~init_marker:"Store_field(field_names, (mlsize_t)col_idx, Val_int(0))";
  check (read_file (find_ladybug_stubs_source ()))
    ~start_marker:"static value arrow_field_names("
    ~end_marker:"static value materialize_arrow_rows("
    ~init_marker:"Store_field(field_names, (mlsize_t)col_idx, Val_int(0))"

let check_column_name_arrays_use_write_barrier () =
  let check source ~start_marker ~end_marker =
    let body = function_source source ~start_marker ~end_marker in
    let copy = require_sub body ~needle:"field_name = caml_copy_string" in
    let store =
      require_sub body
        ~needle:"caml_modify(&Field(field_names, (mlsize_t)col_idx), field_name)"
    in
    Alcotest.(check bool) "field name store uses write barrier after copy" true
      (copy < store)
  in
  check (read_file (find_duckdb_stubs_source ()))
    ~start_marker:"static value duckdb_column_names("
    ~end_marker:"static value materialize_rows(";
  check (read_file (find_ladybug_stubs_source ()))
    ~start_marker:"static value arrow_field_names("
    ~end_marker:"static value materialize_arrow_rows("

let check_foreign_strings_are_owned_before_ocaml_copy () =
  let check source ~start_marker ~end_marker ~alloc_marker ~set_marker
      ~copy_marker ~release_marker =
    let body = function_source source ~start_marker ~end_marker in
    let alloc = require_sub body ~needle:alloc_marker in
    let set = require_sub body ~needle:set_marker in
    let copy = require_sub body ~needle:copy_marker in
    let release = require_sub body ~needle:release_marker in
    Alcotest.(check bool) "foreign string owner is installed before copy" true
      (alloc < set && set < copy && copy < release)
  in
  check (read_file (find_sqlite_stubs_source ()))
    ~start_marker:"CAMLprim value eta_sqlite_expanded_sql("
    ~end_marker:"CAMLprim value eta_sqlite_statement_readonly("
    ~alloc_marker:"owner = sqlite_string_owner_alloc()"
    ~set_marker:"sqlite_string_owner_set(owner, sql)"
    ~copy_marker:"caml_copy_string" ~release_marker:"sqlite_string_owner_release(owner)";
  check (read_file (find_ladybug_stubs_source ()))
    ~start_marker:"static value result_to_string("
    ~end_marker:"static value execute_direct("
    ~alloc_marker:"owner = ladybug_string_owner_alloc()"
    ~set_marker:"ladybug_string_owner_set(owner, s)"
    ~copy_marker:"caml_copy_string" ~release_marker:"ladybug_string_owner_release(owner)"

let check_ladybug_direct_queries_copy_rooted_cypher () =
  let source = read_file (find_ladybug_stubs_source ()) in
  let check_function start_marker end_marker =
    let body = function_source source ~start_marker ~end_marker in
    let owner = require_sub body ~needle:"result_owner = result_owner_alloc()" in
    let copy =
      require_sub body ~needle:"cypher_copy = caml_stat_strdup(String_val(v_cypher))"
    in
    let guard = require_sub body ~needle:"if (cypher_copy == NULL)" in
    let acquire = require_sub body ~needle:"conn_acquire(v_conn, &conn)" in
    let query = require_sub body ~needle:"api.connection_query(&conn, cypher_copy" in
    let release = require_sub body ~needle:"conn_release(v_conn)" in
    Alcotest.(check bool) "owner and strdup guard precede query" true
      (owner < copy && copy < guard && guard < acquire && acquire < query
     && query < release)
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
  let acquire = require_sub body ~needle:"db_state_acquire(state, &db)" in
  let enter = require_sub body ~needle:"caml_enter_blocking_section()" in
  let prepare = require_sub body ~needle:"api.prepare_v2(db, sql" in
  let leave = require_sub body ~needle:"caml_leave_blocking_section()" in
  let free = require_sub_after body ~needle:"caml_stat_free(sql)" leave in
  let release = require_sub body ~needle:"db_state_release(state)" in
  let state_ref = require_sub body ~needle:"db_state_ref(state)" in
  Alcotest.(check bool) "copy guard precedes prepare" true
    (copy < guard && guard < acquire && acquire < prepare);
  Alcotest.(check bool) "prepare runs inside blocking section" true
    (enter < prepare && prepare < leave);
  Alcotest.(check bool) "copied SQL is freed after prepare" true (leave < free);
  Alcotest.(check bool) "prepare releases failed leases before success lease" true
    (release < state_ref)

let check_sqlite_and_turso_column_pointers_are_guarded () =
  let sqlite_source = read_file (find_sqlite_stubs_source ()) in
  let turso_source = read_file (find_turso_stubs_source ()) in
  let check_non_empty_guard source ~start_marker ~end_marker ~pointer =
    let body = function_source source ~start_marker ~end_marker in
    ignore
      (require_sub body
         ~needle:("if (len > 0 && " ^ pointer ^ " == NULL)") :
        int)
  in
  let check_text_oom_guard source ~start_marker ~end_marker ~errcode =
    let body = function_source source ~start_marker ~end_marker in
    ignore (require_sub body ~needle:"if (kind == SQLITE_NULL)" : int);
    ignore
      (require_sub body
         ~needle:("if (text == NULL && " ^ errcode ^ "(db) == SQLITE_NOMEM)") :
        int)
  in
  check_text_oom_guard sqlite_source
    ~start_marker:"CAMLprim value eta_sqlite_column_text("
    ~end_marker:"CAMLprim value eta_sqlite_column_text_bc("
    ~errcode:"sqlite3_errcode";
  check_non_empty_guard sqlite_source
    ~start_marker:"CAMLprim value eta_sqlite_column_blob("
    ~end_marker:"CAMLprim value eta_sqlite_column_blob_bc(" ~pointer:"blob";
  check_text_oom_guard turso_source
    ~start_marker:"CAMLprim value eta_turso_column_text("
    ~end_marker:"CAMLprim value eta_turso_column_text_bc(" ~errcode:"api.errcode";
  check_non_empty_guard turso_source
    ~start_marker:"CAMLprim value eta_turso_column_blob("
    ~end_marker:"CAMLprim value eta_turso_column_blob_bc(" ~pointer:"blob"

let check_interrupts_lock_native_handles () =
  let check source ~struct_marker ~close_start ~close_end ~interrupt_start
      ~interrupt_end ~lock_marker ~unlock_marker ~close_marker ~interrupt_marker
      =
    ignore (require_sub source ~needle:struct_marker : int);
    let close_body =
      function_source source ~start_marker:close_start ~end_marker:close_end
    in
    let interrupt_body =
      function_source source ~start_marker:interrupt_start
        ~end_marker:interrupt_end
    in
    let close_lock = require_sub close_body ~needle:lock_marker in
    let close_call = require_sub close_body ~needle:close_marker in
    let close_unlock =
      require_sub_after close_body ~needle:unlock_marker close_call
    in
    let interrupt_lock = require_sub interrupt_body ~needle:lock_marker in
    let interrupt_call = require_sub interrupt_body ~needle:interrupt_marker in
    let interrupt_unlock =
      require_sub_after interrupt_body ~needle:unlock_marker interrupt_call
    in
    Alcotest.(check bool) "close serializes native handle mutation" true
      (close_lock < close_call && close_call < close_unlock);
    Alcotest.(check bool) "interrupt serializes native handle access" true
      (interrupt_lock < interrupt_call && interrupt_call < interrupt_unlock)
  in
  check (read_file (find_sqlite_stubs_source ()))
    ~struct_marker:"pthread_mutex_t mutex;"
    ~close_start:"CAMLprim intnat eta_sqlite_close("
    ~close_end:"CAMLprim value eta_sqlite_close_bc("
    ~interrupt_start:"CAMLprim value eta_sqlite_interrupt("
    ~interrupt_end:"CAMLprim value eta_sqlite_is_interrupted("
    ~lock_marker:"pthread_mutex_lock(&slot->mutex)"
    ~unlock_marker:"pthread_mutex_unlock(&slot->mutex)"
    ~close_marker:"sqlite3_close_v2(db)"
    ~interrupt_marker:"sqlite3_interrupt(db)";
  check (read_file (find_turso_stubs_source ()))
    ~struct_marker:"pthread_mutex_t mutex;"
    ~close_start:"CAMLprim intnat eta_turso_close("
    ~close_end:"CAMLprim value eta_turso_close_bc("
    ~interrupt_start:"CAMLprim value eta_turso_interrupt("
    ~interrupt_end:"CAMLprim value eta_turso_prepare("
    ~lock_marker:"pthread_mutex_lock(&slot->mutex)"
    ~unlock_marker:"pthread_mutex_unlock(&slot->mutex)"
    ~close_marker:"api.close_v2(db)"
    ~interrupt_marker:"api.interrupt(db)";
  let ladybug_source = read_file (find_ladybug_stubs_source ()) in
  check ladybug_source
    ~struct_marker:"pthread_mutex_t mutex;"
    ~close_start:"static void conn_close_state_blocking("
    ~close_end:"static void fail_connection_closed("
    ~interrupt_start:"CAMLprim value eta_ladybug_interrupt("
    ~interrupt_end:"static int bind_param("
    ~lock_marker:"pthread_mutex_lock(&slot->mutex)"
    ~unlock_marker:"pthread_mutex_unlock(&slot->mutex)"
    ~close_marker:"slot->conn.ptr = NULL"
    ~interrupt_marker:"api.connection_interrupt(&conn)";
  let close_body =
    function_source ladybug_source
      ~start_marker:"static void conn_close_state_blocking("
      ~end_marker:"static void fail_connection_closed("
  in
  let wait = require_sub close_body ~needle:"while (slot->active > 0" in
  let copy = require_sub close_body ~needle:"conn = slot->conn" in
  let clear = require_sub close_body ~needle:"slot->conn.ptr = NULL" in
  let unlock = require_sub_after close_body ~needle:"pthread_mutex_unlock(&slot->mutex)" clear in
  let destroy = require_sub_after close_body ~needle:"api.connection_destroy(&conn)" unlock in
  Alcotest.(check bool) "Ladybug close waits before destroying native handle" true
    (wait < copy && copy < clear && clear < unlock && unlock < destroy);
  let exported_close =
    function_source ladybug_source
      ~start_marker:"CAMLprim value eta_ladybug_close_connection("
      ~end_marker:"CAMLprim value eta_ladybug_interrupt("
  in
  ignore (require_sub exported_close ~needle:"conn_close_state_blocking(state)" : int)

let check_cleanup_handles_survive_blocking_sections () =
  let check_native_state source ~state_helper ~close_start ~close_end =
    ignore (require_sub source ~needle:state_helper : int);
    let body = function_source source ~start_marker:close_start ~end_marker:close_end in
    let state = require_sub body ~needle:state_helper in
    let enter = require_sub body ~needle:"caml_enter_blocking_section();" in
    let leave = require_sub body ~needle:"caml_leave_blocking_section();" in
    Alcotest.(check bool) "stable state loaded before blocking" true
      (state < enter);
    match find_sub_from body ~needle:"Data_custom_val" enter with
    | Some index when index < leave ->
        Alcotest.fail "close touches OCaml custom block inside blocking section"
    | _ -> ()
  in
  check_native_state (read_file (find_sqlite_stubs_source ()))
    ~state_helper:"eta_sqlite_db_state_val(v_db)"
    ~close_start:"CAMLprim intnat eta_sqlite_close("
    ~close_end:"CAMLprim value eta_sqlite_close_bc(";
  check_native_state (read_file (find_turso_stubs_source ()))
    ~state_helper:"eta_turso_db_state_val(v_db)"
    ~close_start:"CAMLprim intnat eta_turso_close("
    ~close_end:"CAMLprim value eta_turso_close_bc(";
  let ladybug_source = read_file (find_ladybug_stubs_source ()) in
  let ladybug_exported_close =
    function_source ladybug_source
      ~start_marker:"CAMLprim value eta_ladybug_close_connection("
      ~end_marker:"CAMLprim value eta_ladybug_interrupt("
  in
  ignore
    (require_sub ladybug_exported_close ~needle:"conn_state_val(v_conn)" : int);
  let ladybug_close_body =
    function_source ladybug_source
      ~start_marker:"static void conn_close_state_blocking("
      ~end_marker:"static void fail_connection_closed("
  in
  let enter =
    require_sub ladybug_close_body ~needle:"caml_enter_blocking_section();"
  in
  let leave =
    require_sub ladybug_close_body ~needle:"caml_leave_blocking_section();"
  in
  (match find_sub_from ladybug_close_body ~needle:"Data_custom_val" enter with
  | Some index when index < leave ->
      Alcotest.fail "Ladybug close touches OCaml custom block inside blocking section"
  | _ -> ());
  let duckdb_source = read_file (find_duckdb_stubs_source ()) in
  let check_duckdb_close ~start_marker ~end_marker ~safe_call ~unsafe_call =
    let body = function_source duckdb_source ~start_marker ~end_marker in
    let enter = require_sub body ~needle:"caml_enter_blocking_section();" in
    let safe = require_sub body ~needle:safe_call in
    Alcotest.(check bool) "close uses local handle in blocking section" true
      (enter < safe);
    match find_sub body ~needle:unsafe_call with
    | None -> ()
    | Some _ -> Alcotest.fail "close passes OCaml custom-block field to C API"
  in
  check_duckdb_close
    ~start_marker:"CAMLprim value eta_duckdb_close_database("
    ~end_marker:"CAMLprim value eta_duckdb_connect("
    ~safe_call:"api.close(&db)" ~unsafe_call:"api.close(&db->db)";
  check_duckdb_close
    ~start_marker:"CAMLprim value eta_duckdb_disconnect("
    ~end_marker:"CAMLprim value eta_duckdb_query("
    ~safe_call:"api.disconnect(&conn)"
    ~unsafe_call:"api.disconnect(&conn->conn)"

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

let check_duckdb_appender_flush_extracts_handle_before_blocking () =
  let source = read_file (find_duckdb_stubs_source ()) in
  let body =
    function_source source
      ~start_marker:"CAMLprim value eta_duckdb_appender_flush("
      ~end_marker:"CAMLprim value eta_duckdb_appender_close("
  in
  let extract = require_sub body ~needle:"duckdb_appender appender =" in
  let enter = require_sub body ~needle:"caml_enter_blocking_section();" in
  let flush = require_sub body ~needle:"api.appender_flush(appender)" in
  Alcotest.(check bool) "handle extracted before blocking" true
    (extract < enter);
  Alcotest.(check bool) "flush uses extracted handle" true (enter < flush);
  match find_sub_from body ~needle:"appender_val(v_appender)" enter with
  | None -> ()
  | Some _ -> Alcotest.fail "appender flush touches OCaml value in blocking section"

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
          Alcotest.test_case "DuckDB appender flush extracts handle" `Quick
            check_duckdb_appender_flush_extracts_handle_before_blocking;
          Alcotest.test_case "DuckDB blob survives driver free GC" `Quick
            check_duckdb_blob_result_survives_driver_free_gc;
          Alcotest.test_case "DuckDB bind params root list cursor" `Quick
            check_duckdb_bind_params_roots_list_cursor;
          Alcotest.test_case "DuckDB query result owner precedes native result"
            `Quick check_duckdb_query_result_owner_precedes_native_result;
          Alcotest.test_case "Ladybug Arrow materialization owns releases" `Quick
            check_ladybug_arrow_materialization_uses_release_owner;
          Alcotest.test_case "DuckDB materialization reuses column names" `Quick
            check_duckdb_materialization_reuses_column_names;
          Alcotest.test_case "Ladybug materialization reuses column names" `Quick
            check_ladybug_arrow_materialization_reuses_column_names;
          Alcotest.test_case "column name arrays initialize GC roots" `Quick
            check_column_name_arrays_initialize_gc_roots;
          Alcotest.test_case "column name arrays use write barrier" `Quick
            check_column_name_arrays_use_write_barrier;
          Alcotest.test_case "foreign strings owned before copy" `Quick
            check_foreign_strings_are_owned_before_ocaml_copy;
          Alcotest.test_case "Ladybug direct queries copy rooted cypher" `Quick
            check_ladybug_direct_queries_copy_rooted_cypher;
          Alcotest.test_case "Turso prepare copies SQL and blocks" `Quick
            check_turso_prepare_copies_sql_and_blocks;
          Alcotest.test_case "SQLite and Turso column pointers are guarded" `Quick
            check_sqlite_and_turso_column_pointers_are_guarded;
          Alcotest.test_case "interrupt locks native handles" `Quick
            check_interrupts_lock_native_handles;
          Alcotest.test_case "cleanup handles survive blocking sections" `Quick
            check_cleanup_handles_survive_blocking_sections;
        ] );
    ]
