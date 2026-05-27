type db
type raw_stmt

type stmt = {
  db : db;
  raw : raw_stmt;
}

type rc = int

type open_mode =
  | Read_only
  | Read_write
  | Read_write_create

type journal_mode =
  [ `Delete
  | `Truncate
  | `Persist
  | `Memory
  | `Wal
  | `Off
  ]

type synchronous =
  [ `Extra
  | `Full
  | `Normal
  | `Off
  ]

type config = {
  path : string;
  mode : open_mode;
  busy_timeout_ms : int option;
  foreign_keys : bool;
  journal_mode : journal_mode option;
  synchronous : synchronous option;
  cache_size : int option;
}

type transaction_mode =
  | Deferred
  | Immediate
  | Exclusive

type error = {
  operation : string;
  code : rc;
  message : string;
}

exception Error of error

let pp_error ppf { operation; code; message } =
  Format.fprintf ppf "%s: %s: %s" operation (string_of_int code) message

external rc_ok : unit -> (int[@untagged])
  = "eta_sqlite_rc_ok_bc" "eta_sqlite_rc_ok"
[@@noalloc]

external rc_row : unit -> (int[@untagged])
  = "eta_sqlite_rc_row_bc" "eta_sqlite_rc_row"
[@@noalloc]

external rc_done : unit -> (int[@untagged])
  = "eta_sqlite_rc_done_bc" "eta_sqlite_rc_done"
[@@noalloc]

external rc_misuse : unit -> (int[@untagged])
  = "eta_sqlite_rc_misuse_bc" "eta_sqlite_rc_misuse"
[@@noalloc]

external rc_range : unit -> (int[@untagged])
  = "eta_sqlite_rc_range_bc" "eta_sqlite_rc_range"
[@@noalloc]

external rc_constraint : unit -> (int[@untagged])
  = "eta_sqlite_rc_constraint_bc" "eta_sqlite_rc_constraint"
[@@noalloc]

let ok = rc_ok ()
let row = rc_row ()
let done_ = rc_done ()
let misuse = rc_misuse ()
let range = rc_range ()
let constraint_ = rc_constraint ()
let busy = 5
let locked = 6
let interrupt_ = 9

let sqlite_integer = 1
let sqlite_float = 2
let sqlite_text = 3
let sqlite_blob = 4
let sqlite_null = 5

let rc_code rc = rc
let rc_equal = Int.equal

let rc_name rc =
  if rc = ok then
    "OK"
  else if rc = row then
    "ROW"
  else if rc = done_ then
    "DONE"
  else if rc = misuse then
    "MISUSE"
  else if rc = range then
    "RANGE"
  else if rc = constraint_ then
    "CONSTRAINT"
  else if rc = busy then
    "BUSY"
  else if rc = locked then
    "LOCKED"
  else if rc = interrupt_ then
    "INTERRUPT"
  else
    "RC(" ^ string_of_int rc ^ ")"

let open_mode_code = function
  | Read_only -> 0
  | Read_write -> 1
  | Read_write_create -> 2

external open_raw : string -> (int[@untagged]) -> db
  = "eta_sqlite_open_bc" "eta_sqlite_open"

let open_ ?(mode = Read_write_create) path =
  open_raw path (open_mode_code mode)

let open_memory () = open_ ":memory:"

let default_config path =
  {
    path;
    mode = Read_write_create;
    busy_timeout_ms = Some 5_000;
    foreign_keys = true;
    journal_mode = None;
    synchronous = Some `Normal;
    cache_size = None;
  }

let memory_config () = { (default_config ":memory:") with journal_mode = Some `Memory }

external close : db -> (int[@untagged])
  = "eta_sqlite_close_bc" "eta_sqlite_close"

external busy_timeout : db -> (int[@untagged]) -> (int[@untagged])
  = "eta_sqlite_busy_timeout_bc" "eta_sqlite_busy_timeout"

external exec_script_raw : db -> string -> (int[@untagged])
  = "eta_sqlite_exec_script_bc" "eta_sqlite_exec_script"

external prepare_raw : db -> string -> raw_stmt = "eta_sqlite_prepare"

external finalize_raw : raw_stmt -> (int[@untagged])
  = "eta_sqlite_finalize_bc" "eta_sqlite_finalize"

let finalize stmt = finalize_raw stmt.raw

external reset_raw : raw_stmt -> (int[@untagged])
  = "eta_sqlite_reset_bc" "eta_sqlite_reset"

let reset stmt = reset_raw stmt.raw

external clear_bindings_raw : raw_stmt -> (int[@untagged]) =
  "eta_sqlite_clear_bindings_bc" "eta_sqlite_clear_bindings"

let clear_bindings stmt = clear_bindings_raw stmt.raw

external bind_parameter_count_raw : raw_stmt -> (int[@untagged]) =
  "eta_sqlite_bind_parameter_count_bc" "eta_sqlite_bind_parameter_count"
[@@noalloc]

let bind_parameter_count stmt = bind_parameter_count_raw stmt.raw

external bind_null_raw : raw_stmt -> (int[@untagged]) -> (int[@untagged]) =
  "eta_sqlite_bind_null_bc" "eta_sqlite_bind_null"

let bind_null stmt index = bind_null_raw stmt.raw index

external bind_int64_raw :
  raw_stmt -> (int[@untagged]) -> (int64[@unboxed]) -> (int[@untagged])
  = "eta_sqlite_bind_int64_bc" "eta_sqlite_bind_int64"

let bind_int64 stmt index value = bind_int64_raw stmt.raw index value

external bind_int_raw :
  raw_stmt -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "eta_sqlite_bind_int_bc" "eta_sqlite_bind_int"
[@@noalloc]

let bind_int stmt index value = bind_int_raw stmt.raw index value

external bind_text_raw : raw_stmt -> (int[@untagged]) -> string -> (int[@untagged])
  = "eta_sqlite_bind_text_bc" "eta_sqlite_bind_text"

let bind_text stmt index value = bind_text_raw stmt.raw index value

external bind_float_raw :
  raw_stmt -> (int[@untagged]) -> (float[@unboxed]) -> (int[@untagged])
  = "eta_sqlite_bind_float_bc" "eta_sqlite_bind_float"

let bind_float stmt index value = bind_float_raw stmt.raw index value

external bind_blob_raw : raw_stmt -> (int[@untagged]) -> bytes -> (int[@untagged])
  = "eta_sqlite_bind_blob_bc" "eta_sqlite_bind_blob"

let bind_blob stmt index value = bind_blob_raw stmt.raw index value

external bind_zeroblob_raw :
  raw_stmt -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "eta_sqlite_bind_zeroblob_bc" "eta_sqlite_bind_zeroblob"

let bind_zeroblob stmt index size = bind_zeroblob_raw stmt.raw index size

external step_raw : raw_stmt -> (int[@untagged])
  = "eta_sqlite_step_bc" "eta_sqlite_step"

let step stmt = step_raw stmt.raw

external column_int64_raw : raw_stmt -> (int[@untagged]) -> (int64[@unboxed])
  = "eta_sqlite_column_int64_bc" "eta_sqlite_column_int64"
[@@noalloc]

let column_int64 stmt index = column_int64_raw stmt.raw index

external column_int_raw : raw_stmt -> (int[@untagged]) -> (int[@untagged])
  = "eta_sqlite_column_int_bc" "eta_sqlite_column_int"
[@@noalloc]

let column_int stmt index = column_int_raw stmt.raw index

external column_text_raw : raw_stmt -> (int[@untagged]) -> string =
  "eta_sqlite_column_text_bc" "eta_sqlite_column_text"

let column_text stmt index = column_text_raw stmt.raw index

external column_float_raw : raw_stmt -> (int[@untagged]) -> (float[@unboxed])
  = "eta_sqlite_column_float_bc" "eta_sqlite_column_float"
[@@noalloc]

let column_float stmt index = column_float_raw stmt.raw index

external column_blob_raw : raw_stmt -> (int[@untagged]) -> bytes =
  "eta_sqlite_column_blob_bc" "eta_sqlite_column_blob"

let column_blob stmt index = column_blob_raw stmt.raw index

external column_is_null_raw : raw_stmt -> (int[@untagged]) -> bool
  = "eta_sqlite_column_is_null_bc" "eta_sqlite_column_is_null"
[@@noalloc]

let column_is_null stmt index = column_is_null_raw stmt.raw index

external column_count_raw : raw_stmt -> (int[@untagged])
  = "eta_sqlite_column_count_bc" "eta_sqlite_column_count"
[@@noalloc]

let column_count stmt = column_count_raw stmt.raw

external column_name_raw : raw_stmt -> (int[@untagged]) -> string =
  "eta_sqlite_column_name_bc" "eta_sqlite_column_name"

let column_name stmt index = column_name_raw stmt.raw index

external column_type_code_raw : raw_stmt -> (int[@untagged]) -> (int[@untagged])
  = "eta_sqlite_column_type_code_bc" "eta_sqlite_column_type_code"
[@@noalloc]

let column_type_code stmt index = column_type_code_raw stmt.raw index

external data_count_raw : raw_stmt -> (int[@untagged])
  = "eta_sqlite_data_count_bc" "eta_sqlite_data_count"
[@@noalloc]

let data_count stmt = data_count_raw stmt.raw

external statement_sql_raw : raw_stmt -> string = "eta_sqlite_statement_sql"
let statement_sql stmt = statement_sql_raw stmt.raw

external expanded_sql_raw : raw_stmt -> string = "eta_sqlite_expanded_sql"
let expanded_sql stmt = expanded_sql_raw stmt.raw

external statement_readonly_raw : raw_stmt -> bool
  = "eta_sqlite_statement_readonly_bc" "eta_sqlite_statement_readonly"
[@@noalloc]

let statement_readonly stmt = statement_readonly_raw stmt.raw

external statement_busy_raw : raw_stmt -> bool
  = "eta_sqlite_statement_busy_bc" "eta_sqlite_statement_busy"
[@@noalloc]

let statement_busy stmt = statement_busy_raw stmt.raw

external changes : db -> (int[@untagged])
  = "eta_sqlite_changes_bc" "eta_sqlite_changes"
[@@noalloc]

external total_changes : db -> (int[@untagged])
  = "eta_sqlite_total_changes_bc" "eta_sqlite_total_changes"
[@@noalloc]

external last_insert_rowid : db -> (int64[@unboxed])
  = "eta_sqlite_last_insert_rowid_bc" "eta_sqlite_last_insert_rowid"
[@@noalloc]

external error_code : db -> (int[@untagged])
  = "eta_sqlite_error_code_bc" "eta_sqlite_error_code"
[@@noalloc]

external extended_error_code : db -> (int[@untagged])
  = "eta_sqlite_extended_error_code_bc" "eta_sqlite_extended_error_code"
[@@noalloc]

external error_message : db -> string = "eta_sqlite_error_message"

external autocommit : db -> bool = "eta_sqlite_autocommit_bc" "eta_sqlite_autocommit"
[@@noalloc]

external database_readonly : db -> string -> bool
  = "eta_sqlite_database_readonly_bc" "eta_sqlite_database_readonly"

external interrupt : db -> unit = "eta_sqlite_interrupt"

external is_interrupted : db -> bool
  = "eta_sqlite_is_interrupted_bc" "eta_sqlite_is_interrupted"
[@@noalloc]

external complete : string -> bool = "eta_sqlite_complete_bc" "eta_sqlite_complete"

let make_error db ~operation code =
  { operation; code; message = error_message db }

let check db ~operation rc =
  if rc = ok then
    Ok ()
  else
    Result.Error (make_error db ~operation rc)

let raise_error err = raise (Error err)

let check_exn db ~operation rc =
  match check db ~operation rc with
  | Ok () -> ()
  | Result.Error err -> raise_error err

let exec_script_result db sql = check db ~operation:"exec script" (exec_script_raw db sql)

let exec_script db sql =
  match exec_script_result db sql with
  | Ok () -> ()
  | Result.Error err -> raise_error err

let journal_mode_sql = function
  | `Delete -> "DELETE"
  | `Truncate -> "TRUNCATE"
  | `Persist -> "PERSIST"
  | `Memory -> "MEMORY"
  | `Wal -> "WAL"
  | `Off -> "OFF"

let synchronous_sql = function
  | `Extra -> "EXTRA"
  | `Full -> "FULL"
  | `Normal -> "NORMAL"
  | `Off -> "OFF"

let bool_sql value = if value then "ON" else "OFF"

let apply_config db config =
  (match config.busy_timeout_ms with
   | None -> ()
   | Some ms -> check_exn db ~operation:"busy_timeout" (busy_timeout db ms));
  exec_script db ("PRAGMA foreign_keys = " ^ bool_sql config.foreign_keys);
  (match config.journal_mode with
   | None -> ()
   | Some mode -> exec_script db ("PRAGMA journal_mode = " ^ journal_mode_sql mode));
  (match config.synchronous with
   | None -> ()
   | Some mode -> exec_script db ("PRAGMA synchronous = " ^ synchronous_sql mode));
  (match config.cache_size with
   | None -> ()
   | Some size -> exec_script db ("PRAGMA cache_size = " ^ string_of_int size))

let open_with_config config =
  let db = open_ ~mode:config.mode config.path in
  match apply_config db config with
  | () -> db
  | exception exn ->
      ignore (close db);
      raise exn

let with_db config f =
  let db = open_with_config config in
  Fun.protect ~finally:(fun () -> ignore (close db)) (fun () -> f db)

let prepare_result db sql =
  match prepare_raw db sql with
  | raw -> Ok { db; raw }
  | exception Failure message ->
      Result.Error { operation = "prepare"; code = error_code db; message }

let prepare db sql =
  match prepare_result db sql with
  | Ok stmt -> stmt
  | Result.Error err -> raise_error err

let exec_result db sql =
  match prepare_result db sql with
  | Result.Error err -> Result.Error err
  | Ok stmt ->
      let rc = step stmt in
      if rc = done_ then (
        let finalize_rc = finalize stmt in
        check db ~operation:"finalize" finalize_rc
      ) else (
        let err = make_error db ~operation:"exec" rc in
        ignore (finalize stmt);
        Result.Error err
      )

let exec db sql =
  match exec_result db sql with
  | Ok () -> ()
  | Result.Error err -> raise_error err

let transaction_mode_sql = function
  | Deferred -> "DEFERRED"
  | Immediate -> "IMMEDIATE"
  | Exclusive -> "EXCLUSIVE"

let begin_transaction_result ?(mode = Deferred) db =
  exec_result db ("BEGIN " ^ transaction_mode_sql mode)

let begin_transaction ?mode db =
  match begin_transaction_result ?mode db with
  | Ok () -> ()
  | Result.Error err -> raise_error err

let commit_result db = exec_result db "COMMIT"

let commit db =
  match commit_result db with
  | Ok () -> ()
  | Result.Error err -> raise_error err

let rollback_result db = exec_result db "ROLLBACK"

let rollback db =
  match rollback_result db with
  | Ok () -> ()
  | Result.Error err -> raise_error err

let with_transaction_result ?mode db f =
  match begin_transaction_result ?mode db with
  | Result.Error _ as err -> err
  | Ok () -> (
      match f db with
      | Ok value -> (
          match commit_result db with
          | Ok () -> Ok value
          | Result.Error _ as err -> err)
      | Result.Error _ as err ->
          ignore (rollback_result db);
          err
      | exception exn ->
          ignore (rollback_result db);
          raise exn)

let with_transaction ?mode db f =
  match with_transaction_result ?mode db (fun db -> Ok (f db)) with
  | Ok value -> value
  | Result.Error err -> raise_error err

let quote_savepoint_name name =
  if name = "" then
    invalid_arg "savepoint name must not be empty";
  let buffer = Buffer.create (String.length name + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (fun c ->
      if Char.equal c '"' then
        Buffer.add_string buffer "\"\""
      else
        Buffer.add_char buffer c)
    name;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let savepoint_result db name = exec_result db ("SAVEPOINT " ^ quote_savepoint_name name)

let savepoint db name =
  match savepoint_result db name with
  | Ok () -> ()
  | Result.Error err -> raise_error err

let release_result db name = exec_result db ("RELEASE " ^ quote_savepoint_name name)

let release db name =
  match release_result db name with
  | Ok () -> ()
  | Result.Error err -> raise_error err

let rollback_to_result db name = exec_result db ("ROLLBACK TO " ^ quote_savepoint_name name)

let rollback_to db name =
  match rollback_to_result db name with
  | Ok () -> ()
  | Result.Error err -> raise_error err

external enable_load_extension : db -> bool -> (int[@untagged])
  = "eta_sqlite_enable_load_extension_bc" "eta_sqlite_enable_load_extension"

external load_extension_raw : db -> string -> (int[@untagged])
  = "eta_sqlite_load_extension_bc" "eta_sqlite_load_extension"

let load_extension_result db path =
  check db ~operation:"load extension" (load_extension_raw db path)

let load_extension db path =
  match load_extension_result db path with
  | Ok () -> ()
  | Result.Error err -> raise_error err

external backup_to_path_raw : db -> string -> (int[@untagged])
  = "eta_sqlite_backup_to_path_bc" "eta_sqlite_backup_to_path"

external restore_from_path_raw : db -> string -> (int[@untagged])
  = "eta_sqlite_restore_from_path_bc" "eta_sqlite_restore_from_path"

let backup_to_path_result db path =
  check db ~operation:"backup to path" (backup_to_path_raw db path)

let backup_to_path db path =
  match backup_to_path_result db path with
  | Ok () -> ()
  | Result.Error err -> raise_error err

let restore_from_path_result db path =
  check db ~operation:"restore from path" (restore_from_path_raw db path)

let restore_from_path db path =
  match restore_from_path_result db path with
  | Ok () -> ()
  | Result.Error err -> raise_error err

let query_one_int_result db sql =
  match prepare_result db sql with
  | Result.Error err -> Result.Error err
  | Ok stmt ->
      let rc = step stmt in
      if rc = row then (
        let value = column_int stmt 0 in
        let drain_rc = step stmt in
        if drain_rc = done_ then (
          let finalize_rc = finalize stmt in
          match check db ~operation:"finalize" finalize_rc with
          | Ok () -> Ok value
          | Result.Error err -> Result.Error err
        ) else (
          let err = make_error db ~operation:"query drain" drain_rc in
          ignore (finalize stmt);
          Result.Error err
        )
      ) else (
        let err = make_error db ~operation:"query" rc in
        ignore (finalize stmt);
        Result.Error err
      )

let query_one_int db sql =
  match query_one_int_result db sql with
  | Ok value -> value
  | Result.Error err -> raise_error err

module Config = struct
  type mode = open_mode =
    | Read_only
    | Read_write
    | Read_write_create

  type t = config = {
    path : string;
    mode : open_mode;
    busy_timeout_ms : int option;
    foreign_keys : bool;
    journal_mode : journal_mode option;
    synchronous : synchronous option;
    cache_size : int option;
  }

  let default = default_config
  let in_memory = memory_config
end

module Error = struct
  type t = error = {
    operation : string;
    code : rc;
    message : string;
  }

  let pp = pp_error
  let to_string err = Format.asprintf "%a" pp err
end

module Testing = struct
  let temp_path_for config =
    if String.equal config.Config.path ":memory:" then
      (config, fun () -> ())
    else
      let suffix =
        match Filename.extension config.path with
        | "" -> ".db"
        | suffix -> suffix
      in
      let path = Filename.temp_file "eta-sqlite-" suffix in
      ({ config with path }, fun () -> if Sys.file_exists path then Sys.remove path)

  let with_db config f =
    let config, cleanup = temp_path_for config in
    Fun.protect ~finally:cleanup @@ fun () ->
    match open_with_config config with
    | db ->
        Fun.protect
          ~finally:(fun () -> ignore (close db))
          (fun () ->
            match f db with
            | result -> result
            | exception exn -> Result.Error (Printexc.to_string exn))
    | exception Error err -> Result.Error (Error.to_string err)
    | exception exn -> Result.Error (Printexc.to_string exn)
end
