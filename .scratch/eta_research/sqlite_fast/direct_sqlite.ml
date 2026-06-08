type db
type raw_stmt

type stmt = {
  db: db;
  raw: raw_stmt;
}

type rc = int

external rc_ok : unit -> (int[@untagged])
  = "eta_sqlite_direct_rc_ok_bc" "eta_sqlite_direct_rc_ok"
[@@noalloc]

external rc_row : unit -> (int[@untagged])
  = "eta_sqlite_direct_rc_row_bc" "eta_sqlite_direct_rc_row"
[@@noalloc]

external rc_done : unit -> (int[@untagged])
  = "eta_sqlite_direct_rc_done_bc" "eta_sqlite_direct_rc_done"
[@@noalloc]

external rc_misuse : unit -> (int[@untagged])
  = "eta_sqlite_direct_rc_misuse_bc" "eta_sqlite_direct_rc_misuse"
[@@noalloc]

external rc_range : unit -> (int[@untagged])
  = "eta_sqlite_direct_rc_range_bc" "eta_sqlite_direct_rc_range"
[@@noalloc]

external rc_constraint : unit -> (int[@untagged])
  = "eta_sqlite_direct_rc_constraint_bc" "eta_sqlite_direct_rc_constraint"
[@@noalloc]

let ok = rc_ok ()
let row = rc_row ()
let done_ = rc_done ()
let misuse = rc_misuse ()
let range = rc_range ()
let constraint_ = rc_constraint ()

external open_memory : unit -> db = "eta_sqlite_direct_open_memory"

external close : db -> (int[@untagged])
  = "eta_sqlite_direct_close_bc" "eta_sqlite_direct_close"

external prepare_raw : db -> string -> raw_stmt = "eta_sqlite_direct_prepare"

let prepare db sql = { db; raw = prepare_raw db sql }

external finalize_raw : raw_stmt -> (int[@untagged])
  = "eta_sqlite_direct_finalize_bc" "eta_sqlite_direct_finalize"

let finalize stmt = finalize_raw stmt.raw

external reset_raw : raw_stmt -> (int[@untagged])
  = "eta_sqlite_direct_reset_bc" "eta_sqlite_direct_reset"

let reset stmt = reset_raw stmt.raw

external clear_bindings_raw : raw_stmt -> (int[@untagged]) =
  "eta_sqlite_direct_clear_bindings_bc" "eta_sqlite_direct_clear_bindings"

let clear_bindings stmt = clear_bindings_raw stmt.raw

external bind_parameter_count_raw : raw_stmt -> (int[@untagged]) =
  "eta_sqlite_direct_bind_parameter_count_bc" "eta_sqlite_direct_bind_parameter_count"
[@@noalloc]

let bind_parameter_count stmt = bind_parameter_count_raw stmt.raw

external bind_null_raw : raw_stmt -> (int[@untagged]) -> (int[@untagged]) =
  "eta_sqlite_direct_bind_null_bc" "eta_sqlite_direct_bind_null"

let bind_null stmt index = bind_null_raw stmt.raw index

external bind_int64_raw :
  raw_stmt -> (int[@untagged]) -> (int64[@unboxed]) -> (int[@untagged])
  = "eta_sqlite_direct_bind_int64_bc" "eta_sqlite_direct_bind_int64"

let bind_int64 stmt index value = bind_int64_raw stmt.raw index value

external bind_int_raw :
  raw_stmt -> (int[@untagged]) -> (int[@untagged]) -> (int[@untagged])
  = "eta_sqlite_direct_bind_int_bc" "eta_sqlite_direct_bind_int"
[@@noalloc]

let bind_int stmt index value = bind_int_raw stmt.raw index value

external bind_text_raw : raw_stmt -> (int[@untagged]) -> string -> (int[@untagged])
  = "eta_sqlite_direct_bind_text_bc" "eta_sqlite_direct_bind_text"

let bind_text stmt index value = bind_text_raw stmt.raw index value

external step_raw : raw_stmt -> (int[@untagged])
  = "eta_sqlite_direct_step_bc" "eta_sqlite_direct_step"

let step stmt = step_raw stmt.raw

external column_int64_raw : raw_stmt -> (int[@untagged]) -> (int64[@unboxed])
  = "eta_sqlite_direct_column_int64_bc" "eta_sqlite_direct_column_int64"
[@@noalloc]

let column_int64 stmt index = column_int64_raw stmt.raw index

external column_int_raw : raw_stmt -> (int[@untagged]) -> (int[@untagged])
  = "eta_sqlite_direct_column_int_bc" "eta_sqlite_direct_column_int"
[@@noalloc]

let column_int stmt index = column_int_raw stmt.raw index

external column_text_raw : raw_stmt -> (int[@untagged]) -> string =
  "eta_sqlite_direct_column_text_bc" "eta_sqlite_direct_column_text"

let column_text stmt index = column_text_raw stmt.raw index

external changes : db -> (int[@untagged])
  = "eta_sqlite_direct_changes_bc" "eta_sqlite_direct_changes"
[@@noalloc]

external error_message : db -> string = "eta_sqlite_direct_error_message"

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
  else
    "RC(" ^ string_of_int rc ^ ")"

let expect_rc label expected actual =
  if actual <> expected then
    failwith
      (label ^ ": expected " ^ rc_name expected ^ ", got " ^ rc_name actual)

let expect_ok label rc = expect_rc label ok rc

let expect_done label rc = expect_rc label done_ rc

let expect_row label rc = expect_rc label row rc

let exec db sql =
  let stmt = prepare db sql in
  match step stmt with
  | rc when rc = done_ ->
      expect_ok ("finalize " ^ sql) (finalize stmt)
  | rc ->
      let finalize_rc = finalize stmt in
      if finalize_rc <> ok then
        failwith ("finalize after failed exec: " ^ rc_name finalize_rc)
      else
        failwith ("exec " ^ sql ^ ": " ^ rc_name rc)

let query_one_int db sql =
  let stmt = prepare db sql in
  match step stmt with
  | rc when rc = row ->
      let value = column_int stmt 0 in
      expect_done ("query drain " ^ sql) (step stmt);
      expect_ok ("query finalize " ^ sql) (finalize stmt);
      value
  | rc ->
      let _ = finalize stmt in
      failwith ("query " ^ sql ^ ": " ^ rc_name rc)
