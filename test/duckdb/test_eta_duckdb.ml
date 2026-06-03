module D = Eta_duckdb
module Effect = Eta.Effect
module Runtime = Eta.Runtime
module Exit = Eta.Exit
module Cause = Eta.Cause

let read_file path =
  let input = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr input)
    (fun () -> really_input_string input (in_channel_length input))

let rec find_sub_from haystack ~needle index =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  if index + needle_len > haystack_len then None
  else if String.sub haystack index needle_len = needle then Some index
  else find_sub_from haystack ~needle (index + 1)

let require_sub haystack ~needle =
  match find_sub_from haystack ~needle 0 with
  | Some index -> index
  | None -> Alcotest.failf "missing source marker: %s" needle

let find_source_file path =
  let candidates =
    [
      Filename.concat "../../../.." path;
      Filename.concat "../../../../.." path;
      path;
      Filename.concat ".." path;
      Filename.concat "../.." path;
      Filename.concat "../../.." path;
    ]
  in
  match List.find_opt Sys.file_exists candidates with
  | Some path -> path
  | None -> Alcotest.failf "could not locate %s from %s" path (Sys.getcwd ())

let source_between source ~start_marker ~end_marker =
  let start = require_sub source ~needle:start_marker in
  let finish =
    match find_sub_from source ~needle:end_marker start with
    | Some finish -> finish
    | None -> Alcotest.failf "missing source end marker: %s" end_marker
  in
  String.sub source start (finish - start)

module Decode_row = struct
  module T = D.Table.Make (struct
    let name = "decode_row"
  end)

  include T

  let id = column "id" D.int
  let name = column "name" D.text
  let active = column "active" D.bool
end

let with_duckdb f =
  match D.available () with
  | Error _ -> ()
  | Ok () -> (
      match D.Database.open_memory () with
      | Error err -> Alcotest.failf "open_memory: %a" D.pp_error err
      | Ok db ->
          Fun.protect
            ~finally:(fun () -> ignore (D.Database.close db))
            (fun () ->
              match D.Connection.connect db with
              | Error err -> Alcotest.failf "connect: %a" D.pp_error err
              | Ok conn ->
                  Fun.protect
                    ~finally:(fun () -> ignore (D.Connection.close conn))
                    (fun () -> f conn)))

let expect_ok label = function
  | Ok value -> value
  | Error err -> Alcotest.failf "%s: %a" label D.pp_error err

let expect_closed label = function
  | Error D.Closed -> ()
  | Error err -> Alcotest.failf "%s: expected closed, got %a" label D.pp_error err
  | Ok () -> Alcotest.failf "%s: expected closed" label

let pp_pool_error ppf = function
  | D.Pool.Duckdb err -> Format.fprintf ppf "Duckdb(%a)" D.pp_error err
  | D.Pool.Invalid_blocking_pool message ->
      Format.fprintf ppf "Invalid_blocking_pool(%S)" message
  | D.Pool.Pool_shutdown -> Format.pp_print_string ppf "Pool_shutdown"
  | D.Pool.Pool_shutdown_timeout ->
      Format.pp_print_string ppf "Pool_shutdown_timeout"
  | D.Pool.Timeout -> Format.pp_print_string ppf "Timeout"

let run_pool_ok rt label effect =
  match Runtime.run rt effect with
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Alcotest.failf "%s: %a" label
        (Cause.pp pp_pool_error)
        cause

let expect_pool_shutdown_timeout label = function
  | Exit.Error (Cause.Fail D.Pool.Pool_shutdown_timeout) -> ()
  | Exit.Ok () -> Alcotest.failf "%s: expected Pool_shutdown_timeout" label
  | Exit.Error cause ->
      Alcotest.failf "%s: expected Pool_shutdown_timeout, got %a" label
        (Cause.pp pp_pool_error)
        cause

let test_pool_create_closes_database_on_eta_pool_create_failure_source () =
  let source = read_file (find_source_file "lib/duckdb/pool.ml") in
  let create =
    source_between source ~start_marker:"let create ?blocking_pool"
      ~end_marker:"let with_connection t f ="
  in
  ignore
    (require_sub source ~needle:"let close_database_on_create_failure" : int);
  ignore (require_sub create ~needle:"Eta.Effect.acquire_release" : int);
  ignore (require_sub create ~needle:"~release:(fun database ->" : int);
  ignore (require_sub source ~needle:"Database.close database" : int);
  ignore (require_sub create ~needle:"Eta.Pool.create" : int);
  ignore
    (require_sub create ~needle:"release_on_create_failure := false" : int)

let test_pool_shutdown_propagates_database_close_error_source () =
  let source = read_file (find_source_file "lib/duckdb/pool.ml") in
  let shutdown =
    source_between source ~start_marker:"let shutdown ?deadline t ="
      ~end_marker:"let stats t ="
  in
  ignore
    (require_sub shutdown
       ~needle:"blocking_result ~name:\"duckdb.close_database\"" :
      int);
  ignore (require_sub shutdown ~needle:"Database.close t.database" : int);
  Alcotest.(check bool)
    "database close result is not discarded" false
    (Option.is_some
       (find_sub_from shutdown ~needle:"ignore (Database.close t.database)" 0))

let test_connect_runs_inside_blocking_section_source () =
  let source = read_file (find_source_file "lib/duckdb/duckdb_stubs.c") in
  let connect =
    source_between source ~start_marker:"CAMLprim value eta_duckdb_connect"
      ~end_marker:"CAMLprim value eta_duckdb_disconnect"
  in
  ignore (require_sub connect ~needle:"duckdb_database db = db_val(v_db)" : int);
  ignore (require_sub connect ~needle:"caml_enter_blocking_section();" : int);
  ignore (require_sub connect ~needle:"rc = api.connect(db, &conn);" : int);
  ignore (require_sub connect ~needle:"caml_leave_blocking_section();" : int)

let test_loader_closes_handle_on_symbol_failure_source () =
  let source = read_file (find_source_file "lib/duckdb/duckdb_stubs.c") in
  let loader =
    source_between source ~start_marker:"static int load_api_unlocked(void)"
      ~end_marker:"static int load_api(void)"
  in
  ignore
    (require_sub source
       ~needle:"static void reset_failed_api_load_unlocked(void)" :
      int);
  ignore
    (require_sub source ~needle:"dlclose(handle);" :
      int);
  ignore
    (require_sub loader ~needle:"reset_failed_api_load_unlocked();" :
      int)

let test_bulk_row_avoids_append_source () =
  let source = read_file (find_source_file "lib/duckdb/bulk_row.ml") in
  Alcotest.(check bool) "bulk row append removed" false
    (Option.is_some (find_sub_from source ~needle:"row @ [" 0))

let test_row_nth_value_uses_sequential_cursor_source () =
  let source = read_file (find_source_file "lib/duckdb/types.ml") in
  let body =
    source_between source ~start_marker:"let row_nth_value index row ="
      ~end_marker:"type raw_database"
  in
  ignore (require_sub body ~needle:"row_decode_cursor" : int);
  ignore (require_sub body ~needle:"cached_row == row" : int);
  ignore (require_sub body ~needle:"index >= cursor.next_index" : int)

let test_row_decode_cursor_preserves_indexed_decoding () =
  let row =
    [
      ("id", D.Value.Int 7);
      ("name", D.Value.String "ada");
      ("active", D.Value.Bool true);
    ]
  in
  let query =
    D.Select.from Decode_row.table
      D.Projection.(t3 (one Decode_row.id) (one Decode_row.name) (one Decode_row.active))
    |> D.Select.compile
  in
  let id, name, active = D.Compiled.select_decode query row in
  Alcotest.(check int) "first column" 7 id;
  Alcotest.(check string) "second column" "ada" name;
  Alcotest.(check bool) "third column" true active;
  let id, name, active = D.Compiled.select_decode query row in
  Alcotest.(check int) "rewind first column" 7 id;
  Alcotest.(check string) "rewind second column" "ada" name;
  Alcotest.(check bool) "rewind third column" true active

let test_transaction_begin_uses_duckdb_syntax_source () =
  let connection = read_file (find_source_file "lib/duckdb/connection.ml") in
  let interface = read_file (find_source_file "lib/duckdb/eta_duckdb.mli") in
  Alcotest.(check bool)
    "no SQLite BEGIN IMMEDIATE mode" false
    (Option.is_some (find_sub_from connection ~needle:"BEGIN IMMEDIATE" 0));
  Alcotest.(check bool)
    "DuckDB exposes no transaction_mode" false
    (Option.is_some (find_sub_from interface ~needle:"transaction_mode" 0));
  ignore
    (require_sub connection ~needle:"exec_script conn \"BEGIN TRANSACTION\"" : int)

let test_pool_shutdown_timeout_keeps_active_connection_open () =
  match D.available () with
  | Error _ -> ()
  | Ok () ->
      Eio_main.run @@ fun stdenv ->
      Eio.Switch.run @@ fun sw ->
      let rt =
        Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
      in
      let pool =
        D.Pool.create ~max_size:1 { path = None; threads = None }
        |> run_pool_ok rt "create pool"
      in
      let lease_started, lease_started_u = Eio.Promise.create () in
      let release_lease, release_lease_u = Eio.Promise.create () in
      let lease_result =
        Eio.Fiber.fork_promise ~sw (fun () ->
            Runtime.run rt
              (D.Pool.with_connection pool (fun conn ->
                   Effect.sync (fun () ->
                       Eio.Promise.resolve lease_started_u ();
                       Eio.Promise.await release_lease)
                   |> Effect.bind (fun () ->
                          match D.Connection.query conn "SELECT 1" [] with
                          | Ok rows -> Effect.pure rows
                          | Error err -> Effect.fail (D.Pool.Duckdb err)))))
      in
      Eio.Promise.await lease_started;
      D.Pool.shutdown ~deadline:(Eta.Duration.ms 1) pool
      |> Runtime.run rt
      |> expect_pool_shutdown_timeout "shutdown with active lease";
      Eio.Promise.resolve release_lease_u ();
      (match Eio.Promise.await_exn lease_result with
      | Exit.Ok _ -> ()
      | Exit.Error cause ->
          Alcotest.failf
            "active lease should stay usable after shutdown timeout: %a"
            (Cause.pp pp_pool_error)
            cause);
      ignore (Runtime.run rt (D.Pool.shutdown pool))

let test_appender_failed_partial_row_closes_handle () =
  with_duckdb @@ fun conn ->
  D.Connection.exec_script conn
    "CREATE TABLE appender_guard (id BIGINT, name VARCHAR)"
  |> expect_ok "create table";
  let appender =
    D.Appender.create conn ~table:"appender_guard" |> expect_ok "create appender"
  in
  (match
     D.Appender.append_row appender
       [ D.Value.Int 1; D.Value.List [ D.Value.String "bad" ] ]
   with
  | Error _ -> ()
  | Ok () -> Alcotest.fail "expected unsupported appender value failure");
  D.Appender.append_row appender [ D.Value.Int 2; D.Value.String "ok" ]
  |> expect_closed "append after failed partial row"

let test_appender_failure_paths_close_raw_source () =
  let source = read_file (find_source_file "lib/duckdb/appender.ml") in
  let append_row =
    source_between source ~start_marker:"let append_row appender values ="
      ~end_marker:"let flush appender ="
  in
  let flush =
    source_between source ~start_marker:"let flush appender ="
      ~end_marker:"let close appender ="
  in
  let close =
    source_between source ~start_marker:"let close appender ="
      ~end_marker:"let with_appender"
  in
  ignore (require_sub source ~needle:"let close_raw appender =" : int);
  ignore (require_sub append_row ~needle:"ignore (close_raw appender)" : int);
  ignore (require_sub flush ~needle:"ignore (close_raw appender)" : int);
  ignore (require_sub close ~needle:"close_raw appender" : int)

let () =
  Alcotest.run "eta-duckdb"
    [
      ( "pool",
        [
          Alcotest.test_case
            "create closes database if Eta pool creation fails" `Quick
            test_pool_create_closes_database_on_eta_pool_create_failure_source;
          Alcotest.test_case "shutdown propagates database close error" `Quick
            test_pool_shutdown_propagates_database_close_error_source;
        ] );
      ( "ffi",
        [
          Alcotest.test_case "connect uses blocking section" `Quick
            test_connect_runs_inside_blocking_section_source;
          Alcotest.test_case "loader closes handle on symbol failure" `Quick
            test_loader_closes_handle_on_symbol_failure_source;
          Alcotest.test_case "bulk row avoids append" `Quick
            test_bulk_row_avoids_append_source;
        ] );
      ( "row",
        [
          Alcotest.test_case "indexed decode uses sequential cursor" `Quick
            test_row_nth_value_uses_sequential_cursor_source;
          Alcotest.test_case "decode cursor preserves indexed decoding" `Quick
            test_row_decode_cursor_preserves_indexed_decoding;
        ] );
      ( "appender",
        [
          Alcotest.test_case "failed partial row closes handle" `Quick
            test_appender_failed_partial_row_closes_handle;
          Alcotest.test_case "failure paths close raw appender" `Quick
            test_appender_failure_paths_close_raw_source;
          Alcotest.test_case
            "pool shutdown timeout keeps active connection open" `Quick
            test_pool_shutdown_timeout_keeps_active_connection_open;
        ] );
      ( "transaction",
        [
          Alcotest.test_case "begin uses DuckDB syntax" `Quick
            test_transaction_begin_uses_duckdb_syntax_source;
        ] );
    ]
