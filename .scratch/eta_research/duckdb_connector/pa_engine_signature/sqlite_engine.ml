(** Attempt to satisfy ENGINE with the existing Sqlite module.

    PROBE: Does this require changing public Sqlite types?
    Does it hide semantics callers depend on?
    Does it add extra boxing? *)

module Error = struct
  type t = Sql.error

  let pp = Sql.pp_error
  let to_string = Sql.show_error
end

module Value = struct
  type t = Sql.Value.t =
    | Null
    | Int of int
    | Int64 of int64
    | Float of float
    | String of string
    | Bool of bool
    | Bytes of bytes

  let null = Sql.Value.null
  let int = Sql.Value.int
  let int64 = Sql.Value.int64
  let float = Sql.Value.float
  let string = Sql.Value.string
  let bool = Sql.Value.bool
  let bytes = Sql.Value.bytes
end

type database = Sqlite.db
type connection = Sqlite.db  (* SQLite: database = connection *)
type statement = Sqlite.stmt
type result = unit  (* SQLite: no separate result type *)

let open_database path =
  try Ok (Sqlite.open_ path)
  with Sqlite.Error err -> Error (Sql.Sqlite err)

let close_database db =
  let _rc = Sqlite.close db in
  Ok ()

let connect db = Ok db  (* SQLite: database IS the connection *)
let disconnect _conn = Ok ()  (* SQLite: disconnect = close database *)

let prepare conn sql =
  try Ok (Sqlite.prepare conn sql)
  with Sqlite.Error err -> Error (Sql.Sqlite err)

let bind stmt idx value =
  try
    let _rc = match value with
     | Value.Null -> Sqlite.bind_null stmt idx
     | Value.Int i -> Sqlite.bind_int stmt idx i
     | Value.Int64 i -> Sqlite.bind_int64 stmt idx i
     | Value.Float f -> Sqlite.bind_float stmt idx f
     | Value.String s -> Sqlite.bind_text stmt idx s
     | Value.Bool b -> Sqlite.bind_int stmt idx (if b then 1 else 0)
     | Value.Bytes b -> Sqlite.bind_blob stmt idx b
    in
    Ok ()
  with Sqlite.Error err -> Error (Sql.Sqlite err)

let step stmt =
  let rc = Sqlite.step stmt in
  if rc = Sqlite.row then Ok true
  else if rc = Sqlite.done_ then Ok false
  else Error (Sql.Sqlite { Sqlite.operation = "step"; code = rc; message = Sqlite.rc_name rc })

let reset stmt =
  let _rc = Sqlite.reset stmt in
  Ok ()

let finalize stmt =
  let _rc = Sqlite.finalize stmt in
  Ok ()

let exec conn sql =
  try Ok (Sqlite.exec conn sql)
  with Sqlite.Error err -> Error (Sql.Sqlite err)

let column_count stmt = Sqlite.column_count stmt
let column_name stmt idx = Sqlite.column_name stmt idx
let column_type stmt idx = Sqlite.column_type_code stmt idx

let column_int64 stmt idx = Sqlite.column_int64 stmt idx
let column_double stmt idx = Sqlite.column_float stmt idx
let column_text stmt idx = Sqlite.column_text stmt idx
let column_blob stmt idx = Sqlite.column_blob stmt idx
let column_is_null stmt idx = Sqlite.column_is_null stmt idx

let interrupt conn = Sqlite.interrupt conn

let is_thread_safe = true
