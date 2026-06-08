type database = nativeint
type connection = database
type statement = nativeint
type result = unit

module Error = struct
  type t = { operation : string; message : string }

  let pp ppf { operation; message } =
    Format.fprintf ppf "%s: %s" operation message

  let to_string err = Format.asprintf "%a" pp err
end

module Value = struct
  type t =
    | Null
    | Int of int
    | Int64 of int64
    | Float of float
    | String of string
    | Bool of bool
    | Bytes of bytes

  let null = Null
  let int value = Int value
  let int64 value = Int64 value
  let float value = Float value
  let string value = String value
  let bool value = Bool value
  let bytes value = Bytes value
end

external raw_open : string -> database = "eta_turso_pt_open"
external raw_close : database -> unit = "eta_turso_pt_close"
external raw_exec : connection -> string -> unit = "eta_turso_pt_exec"
external raw_prepare : connection -> string -> statement = "eta_turso_pt_prepare"
external raw_finalize : statement -> unit = "eta_turso_pt_finalize"
external raw_reset : statement -> unit = "eta_turso_pt_reset"
external raw_step : statement -> int = "eta_turso_pt_step"
external raw_bind_null : statement -> int -> unit = "eta_turso_pt_bind_null"
external raw_bind_int64 : statement -> int -> int64 -> unit = "eta_turso_pt_bind_int64"
external raw_bind_double : statement -> int -> float -> unit = "eta_turso_pt_bind_double"
external raw_bind_text : statement -> int -> string -> unit = "eta_turso_pt_bind_text"
external raw_bind_blob : statement -> int -> bytes -> unit = "eta_turso_pt_bind_blob"
external column_count : statement -> int = "eta_turso_pt_column_count"
external column_name : statement -> int -> string = "eta_turso_pt_column_name"
external column_type : statement -> int -> int = "eta_turso_pt_column_type"
external column_int64 : statement -> int -> int64 = "eta_turso_pt_column_int64"
external column_double : statement -> int -> float = "eta_turso_pt_column_double"
external column_text : statement -> int -> string = "eta_turso_pt_column_text"
external column_blob : statement -> int -> bytes = "eta_turso_pt_column_blob"
external raw_column_is_null : statement -> int -> bool = "eta_turso_pt_column_is_null"
external interrupt : connection -> unit = "eta_turso_pt_interrupt"

let protect operation f =
  try Ok (f ()) with Failure message -> Error { Error.operation; message }

let open_database path = protect "open_database" (fun () -> raw_open path)
let close_database db = protect "close_database" (fun () -> raw_close db)
let connect db = Ok db
let disconnect _conn = Ok ()
let prepare conn sql = protect "prepare" (fun () -> raw_prepare conn sql)
let reset stmt = protect "reset" (fun () -> raw_reset stmt)
let finalize stmt = protect "finalize" (fun () -> raw_finalize stmt)
let exec conn sql = protect "exec" (fun () -> raw_exec conn sql)

let bind stmt index value =
  protect "bind" (fun () ->
      match value with
      | Value.Null -> raw_bind_null stmt index
      | Int value -> raw_bind_int64 stmt index (Int64.of_int value)
      | Int64 value -> raw_bind_int64 stmt index value
      | Float value -> raw_bind_double stmt index value
      | String value -> raw_bind_text stmt index value
      | Bool value -> raw_bind_int64 stmt index (if value then 1L else 0L)
      | Bytes value -> raw_bind_blob stmt index value)

let step stmt =
  protect "step" (fun () ->
      match raw_step stmt with
      | 100 -> true
      | 101 -> false
      | code -> failwith (Printf.sprintf "unexpected sqlite step code %d" code))

let column_is_null = raw_column_is_null
let is_thread_safe = true
