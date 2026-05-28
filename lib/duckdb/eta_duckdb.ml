module Value = struct
  type t =
    | Null
    | Bool of bool
    | Int of int
    | Int64 of int64
    | Float of float
    | String of string
    | Bytes of bytes
    | Decimal of string
    | Date of string
    | Time of string
    | Timestamp of string
    | Uuid of string
    | Json of string
    | Enum of string
    | List of t list
    | Struct of (string * t) list

  let rec to_string = function
    | Null -> "NULL"
    | Bool true -> "true"
    | Bool false -> "false"
    | Int value -> string_of_int value
    | Int64 value -> Int64.to_string value
    | Float value -> string_of_float value
    | String value -> value
    | Bytes value -> Bytes.to_string value
    | Decimal value | Date value | Time value | Timestamp value | Uuid value
    | Json value | Enum value -> value
    | List values -> "[" ^ String.concat ", " (List.map to_string values) ^ "]"
    | Struct fields ->
        fields
        |> List.map (fun (name, value) -> name ^ "=" ^ to_string value)
        |> String.concat ", "
end

module Row = struct
  type t = (string * Value.t) list

  let get field row = List.assoc_opt field row
  let fields row = List.map fst row

  let int field row =
    match get field row with
    | Some (Value.Int value) -> Some value
    | Some (Int64 value) ->
        let min = Int64.of_int min_int in
        let max = Int64.of_int max_int in
        if Int64.compare value min >= 0 && Int64.compare value max <= 0 then
          Some (Int64.to_int value)
        else
          None
    | _ -> None

  let int64 field row =
    match get field row with
    | Some (Value.Int value) -> Some (Int64.of_int value)
    | Some (Int64 value) -> Some value
    | _ -> None

  let string field row =
    match get field row with
    | Some (Value.String value | Decimal value | Date value | Time value
           | Timestamp value | Uuid value | Json value | Enum value) -> Some value
    | _ -> None

  let bool field row = match get field row with Some (Value.Bool value) -> Some value | _ -> None
  let float field row = match get field row with Some (Value.Float value) -> Some value | _ -> None
  let bytes field row = match get field row with Some (Value.Bytes value) -> Some value | _ -> None
end

type raw_database
type raw_connection
type raw_appender

type database = {
  raw : raw_database;
  mutable closed : bool;
}

type connection = {
  database : database;
  raw : raw_connection;
  mutable closed : bool;
}

type appender = {
  connection : connection;
  raw : raw_appender;
  mutable closed : bool;
}

type config = {
  path : string option;
  threads : int option;
}

type transaction_mode =
  | Deferred
  | Immediate

type error =
  | Library_unavailable of string
  | Driver_error of {
      operation : string;
      message : string;
    }
  | Invalid_value of string
  | Closed

exception Error of error

external raw_available : unit -> string option = "eta_duckdb_available"
external raw_version : unit -> string = "eta_duckdb_version"
external raw_open : string -> raw_database = "eta_duckdb_open"
external raw_close_database : raw_database -> unit = "eta_duckdb_close_database"
external raw_connect : raw_database -> raw_connection = "eta_duckdb_connect"
external raw_disconnect : raw_connection -> unit = "eta_duckdb_disconnect"
external raw_interrupt : raw_connection -> unit = "eta_duckdb_interrupt"
external raw_query : raw_connection -> string -> Value.t list -> Row.t list = "eta_duckdb_query"
external raw_execute : raw_connection -> string -> Value.t list -> int = "eta_duckdb_execute"
external raw_exec_script : raw_connection -> string -> unit = "eta_duckdb_exec_script"
external raw_appender_create : raw_connection -> string option -> string -> raw_appender = "eta_duckdb_appender_create"
external raw_appender_append_row : raw_appender -> Value.t list -> unit = "eta_duckdb_appender_append_row"
external raw_appender_flush : raw_appender -> unit = "eta_duckdb_appender_flush"
external raw_appender_close : raw_appender -> unit = "eta_duckdb_appender_close"

let pp_error ppf = function
  | Library_unavailable message -> Format.fprintf ppf "duckdb library unavailable: %s" message
  | Driver_error { operation; message } -> Format.fprintf ppf "%s: %s" operation message
  | Invalid_value message -> Format.fprintf ppf "invalid DuckDB value: %s" message
  | Closed -> Format.pp_print_string ppf "DuckDB handle is closed"

let show_error err = Format.asprintf "%a" pp_error err
let pp_duckdb_error = pp_error

let available () =
  match raw_available () with
  | None -> Ok ()
  | Some message -> Result.Error (Library_unavailable message)

let wrap operation f =
  match available () with
  | Result.Error _ as err -> err
  | Ok () -> (
      match f () with
      | value -> Ok value
      | exception Failure message -> Result.Error (Driver_error { operation; message }))

let version () = wrap "version" raw_version
let if_database_open (db : database) f = if db.closed then Result.Error Closed else f ()

let if_connection_open (conn : connection) f =
  if conn.closed || conn.database.closed then Result.Error Closed else f ()

let if_appender_open (appender : appender) f =
  if appender.closed || appender.connection.closed then Result.Error Closed else f ()

module Database = struct
  type t = database

  let open_ config =
    wrap "open" @@ fun () ->
    let path = Option.value config.path ~default:"" in
    let db = { raw = raw_open path; closed = false } in
    (match config.threads with
     | None -> ()
     | Some threads ->
         if threads <= 0 then invalid_arg "Eta_duckdb.Database.open_: threads must be positive";
         let conn = { database = db; raw = raw_connect db.raw; closed = false } in
         Fun.protect
           ~finally:(fun () ->
             conn.closed <- true;
             raw_disconnect conn.raw)
           (fun () ->
             raw_exec_script conn.raw ("PRAGMA threads=" ^ string_of_int threads)));
    db

  let open_memory () = open_ { path = None; threads = None }

  let close db =
    if_database_open db @@ fun () ->
    db.closed <- true;
    wrap "close database" (fun () -> raw_close_database db.raw)
end

module Connection = struct
  type t = connection

  let connect database =
    if_database_open database @@ fun () ->
    wrap "connect" (fun () ->
        { database; raw = raw_connect database.raw; closed = false })

  let close conn =
    if_connection_open conn @@ fun () ->
    conn.closed <- true;
    wrap "disconnect" (fun () -> raw_disconnect conn.raw)

  let interrupt conn = if not conn.closed then raw_interrupt conn.raw

  let query conn sql params =
    if_connection_open conn @@ fun () ->
    wrap "query" (fun () -> raw_query conn.raw sql params)

  let execute conn sql params =
    if_connection_open conn @@ fun () ->
    wrap "execute" (fun () -> raw_execute conn.raw sql params)

  let exec_script conn sql =
    if_connection_open conn @@ fun () ->
    wrap "exec script" (fun () -> raw_exec_script conn.raw sql)

  let begin_transaction ?(mode = Deferred) conn =
    let sql =
      match mode with
      | Deferred -> "BEGIN TRANSACTION"
      | Immediate -> "BEGIN IMMEDIATE TRANSACTION"
    in
    exec_script conn sql

  let commit conn = exec_script conn "COMMIT"
  let rollback conn = exec_script conn "ROLLBACK"

  let transaction ?mode conn f =
    match begin_transaction ?mode conn with
    | Result.Error _ as err -> err
    | Ok () -> (
        match f conn with
        | Ok value -> (
            match commit conn with
            | Ok () -> Ok value
            | Result.Error _ as err -> err)
        | Result.Error _ as err ->
            ignore (rollback conn);
            err
        | exception exn ->
            ignore (rollback conn);
            raise exn)
end

module Appender = struct
  type t = appender

  let create ?schema connection ~table =
    if_connection_open connection @@ fun () ->
    wrap "appender create" (fun () ->
        { connection; raw = raw_appender_create connection.raw schema table; closed = false })

  let append_row appender values =
    if_appender_open appender @@ fun () ->
    wrap "appender append row" (fun () -> raw_appender_append_row appender.raw values)

  let flush appender =
    if_appender_open appender @@ fun () ->
    wrap "appender flush" (fun () -> raw_appender_flush appender.raw)

  let close appender =
    if_appender_open appender @@ fun () ->
    appender.closed <- true;
    wrap "appender close" (fun () -> raw_appender_close appender.raw)

  let with_appender ?schema connection ~table f =
    match create ?schema connection ~table with
    | Result.Error _ as err -> err
    | Ok appender -> (
        match f appender with
        | Ok value -> (
            match close appender with
            | Ok () -> Ok value
            | Result.Error _ as err -> err)
        | Result.Error _ as err ->
            ignore (close appender);
            err
        | exception exn ->
            ignore (close appender);
            raise exn)
end

module Pool = struct
  type raw_error = [ `Duckdb of error | `Pool_shutdown | `Pool_shutdown_timeout | `Timeout ]

  type t = {
    database : database;
    pool : (connection, raw_error) Eta.Pool.t;
  }

  type nonrec error =
    | Duckdb of error
    | Pool_shutdown
    | Pool_shutdown_timeout
    | Timeout

  let to_public_error = function
    | `Duckdb err -> Duckdb err
    | `Pool_shutdown -> Pool_shutdown
    | `Pool_shutdown_timeout -> Pool_shutdown_timeout
    | `Timeout -> Timeout

  let to_raw_error = function
    | Duckdb err -> `Duckdb err
    | Pool_shutdown -> `Pool_shutdown
    | Pool_shutdown_timeout -> `Pool_shutdown_timeout
    | Timeout -> `Timeout

  let public effect = Eta.Effect.map_error to_public_error effect

  let lift_result = function
    | Ok value -> Eta.Effect.pure value
    | Result.Error err -> Eta.Effect.fail (`Duckdb err)

  let blocking_result ?blocking_pool ?name f =
    Eta.Effect.blocking ?pool:blocking_pool ?name f |> Eta.Effect.bind lift_result

  let timed_blocking_result ?blocking_pool ~timeout ~conn ~name f =
    let query =
      Eta.Effect.blocking ?pool:blocking_pool ~name ~on_cancel:(fun () ->
          Connection.interrupt conn)
        f
      |> Eta.Effect.map (function
           | Ok value -> `Query_ok value
           | Result.Error err -> `Query_error err)
    in
    let timeout =
      Eta.Effect.delay timeout
        (Eta.Effect.sync (fun () -> Connection.interrupt conn)
         |> Eta.Effect.map (fun () -> `Timed_out))
    in
    Eta.Effect.race [ query; timeout ]
    |> Eta.Effect.bind (function
         | `Query_ok value -> Eta.Effect.pure value
         | `Query_error err -> Eta.Effect.fail (`Duckdb err)
         | `Timed_out -> Eta.Effect.fail `Timeout)

  let create ?blocking_pool ?name ?(max_size = 10) ?max_idle ?idle_lifetime
      ?max_lifetime config =
    blocking_result ?blocking_pool ~name:"duckdb.open" (fun () ->
        Database.open_ config)
    |> Eta.Effect.bind (fun database ->
           Eta.Pool.create ?name ~kind:"duckdb" ~max_size ?max_idle
             ?idle_lifetime ?max_lifetime
             ~acquire:
               (blocking_result ?blocking_pool ~name:"duckdb.connect" (fun () ->
                    Connection.connect database))
             ~release:(fun conn ->
               Eta.Effect.blocking ?pool:blocking_pool ~name:"duckdb.disconnect"
                 (fun () -> ignore (Connection.close conn)))
             ~health_check:(fun conn ->
               blocking_result ?blocking_pool ~name:"duckdb.ping" (fun () ->
                   match Connection.query conn "SELECT 1" [] with
                   | Ok _ -> Ok ()
                   | Result.Error _ as err -> err))
             ()
           |> Eta.Effect.map (fun pool -> { database; pool }))
    |> public

  let with_connection t f =
    Eta.Pool.with_resource t.pool (fun conn ->
        f conn |> Eta.Effect.map_error to_raw_error)
    |> public

  let query ?blocking_pool ~timeout t sql params =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.query"
          (fun () -> Connection.query conn sql params)
        |> public)

  let execute ?blocking_pool ~timeout t sql params =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.execute"
          (fun () -> Connection.execute conn sql params)
        |> public)

  let shutdown ?deadline t =
    Eta.Pool.shutdown ?deadline t.pool
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.blocking ~name:"duckdb.close_database" (fun () ->
               ignore (Database.close t.database)))
    |> public

  let stats t = Eta.Pool.stats t.pool
end
