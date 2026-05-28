module Value = struct
  type node = {
    id : int64 option;
    labels : string list;
    properties : (string * t) list;
  }

  and rel = {
    id : int64 option;
    src : int64 option;
    dst : int64 option;
    label : string option;
    properties : (string * t) list;
  }

  and path = {
    nodes : node list;
    rels : rel list;
  }

  and t =
    | Null
    | Bool of bool
    | Int of int64
    | Float of float
    | String of string
    | List of t list
    | Map of (string * t) list
    | Node of node
    | Rel of rel
    | Path of path
end

module Param = struct
  type t = string * Value.t

  let null name = (name, Value.Null)
  let bool name value = (name, Value.Bool value)
  let int name value = (name, Value.Int value)
  let float name value = (name, Value.Float value)
  let string name value = (name, Value.String value)
end

type raw_database
type raw_connection

type database = {
  raw : raw_database;
  mutable closed : bool;
}

type connection = {
  database : database;
  raw : raw_connection;
  mutable closed : bool;
}

type error_category =
  | Query_syntax
  | Type_mismatch
  | Integrity_violation
  | Timeout_or_interrupt
  | Connection_closed_or_invalid
  | Other

type error =
  | Library_unavailable of string
  | Driver_error of {
      operation : string;
      category : error_category;
      message : string;
    }
  | Invalid_value of string
  | Closed

exception Error of error

external raw_available : unit -> string option = "eta_ladybug_available"
external raw_version : unit -> string = "eta_ladybug_version"
external raw_open : string -> raw_database = "eta_ladybug_open"
external raw_close_database : raw_database -> unit = "eta_ladybug_close_database"
external raw_connect : raw_database -> raw_connection = "eta_ladybug_connect"
external raw_close_connection : raw_connection -> unit = "eta_ladybug_close_connection"
external raw_interrupt : raw_connection -> unit = "eta_ladybug_interrupt"
external raw_query_string : raw_connection -> string -> Param.t list -> string = "eta_ladybug_query_string"

let lower_ascii value = String.lowercase_ascii value

let contains haystack needle =
  let haystack = lower_ascii haystack in
  let needle = lower_ascii needle in
  let h_len = String.length haystack in
  let n_len = String.length needle in
  let rec at pos i =
    i = n_len
    || (pos + i < h_len
       && Char.equal haystack.[pos + i] needle.[i]
       && at pos (i + 1))
  in
  let rec loop pos =
    n_len = 0
    || (pos + n_len <= h_len && (at pos 0 || loop (pos + 1)))
  in
  loop 0

let classify_error message =
  if contains message "parser exception" then Query_syntax
  else if contains message "binder exception" then Type_mismatch
  else if contains message "duplicated primary key" then Integrity_violation
  else if contains message "interrupted" then Timeout_or_interrupt
  else if contains message "closed" || contains message "invalid connection" then
    Connection_closed_or_invalid
  else Other

let pp_category ppf = function
  | Query_syntax -> Format.pp_print_string ppf "query syntax"
  | Type_mismatch -> Format.pp_print_string ppf "type mismatch"
  | Integrity_violation -> Format.pp_print_string ppf "integrity violation"
  | Timeout_or_interrupt -> Format.pp_print_string ppf "timeout or interrupt"
  | Connection_closed_or_invalid -> Format.pp_print_string ppf "closed or invalid connection"
  | Other -> Format.pp_print_string ppf "other"

let pp_error ppf = function
  | Library_unavailable message -> Format.fprintf ppf "ladybug library unavailable: %s" message
  | Driver_error { operation; category; message } ->
      Format.fprintf ppf "%s: %a: %s" operation pp_category category message
  | Invalid_value message -> Format.fprintf ppf "invalid LadybugDB value: %s" message
  | Closed -> Format.pp_print_string ppf "LadybugDB handle is closed"

let show_error err = Format.asprintf "%a" pp_error err
let pp_ladybug_error = pp_error

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
      | exception Failure message ->
          Result.Error
            (Driver_error
               { operation; category = classify_error message; message }))

let version () = wrap "version" raw_version
let if_database_open db f = if db.closed then Result.Error Closed else f ()
let if_connection_open conn f = if conn.closed || conn.database.closed then Result.Error Closed else f ()

module Database = struct
  type t = database

  let open_ ~path =
    wrap "database open" (fun () -> { raw = raw_open path; closed = false })

  let open_memory () = open_ ~path:":memory:"

  let close db =
    if_database_open db @@ fun () ->
    db.closed <- true;
    wrap "database close" (fun () -> raw_close_database db.raw)
end

module Connection = struct
  type t = connection

  let connect database =
    if_database_open database @@ fun () ->
    wrap "connection open" (fun () ->
        { database; raw = raw_connect database.raw; closed = false })

  let close conn =
    if_connection_open conn @@ fun () ->
    conn.closed <- true;
    wrap "connection close" (fun () -> raw_close_connection conn.raw)

  let interrupt conn = if not conn.closed then raw_interrupt conn.raw

  let query_string ?(params = []) conn cypher =
    if_connection_open conn @@ fun () ->
    wrap "query" (fun () -> raw_query_string conn.raw cypher params)

  let exec ?params conn cypher = query_string ?params conn cypher |> Result.map (fun _ -> ())
end

module Pool = struct
  type raw_error = [ `Ladybug of error | `Pool_shutdown | `Pool_shutdown_timeout | `Timeout ]
  type t = (connection, raw_error) Eta.Pool.t

  type nonrec error =
    | Ladybug of error
    | Pool_shutdown
    | Pool_shutdown_timeout
    | Timeout

  let to_public_error = function
    | `Ladybug err -> Ladybug err
    | `Pool_shutdown -> Pool_shutdown
    | `Pool_shutdown_timeout -> Pool_shutdown_timeout
    | `Timeout -> Timeout

  let to_raw_error = function
    | Ladybug err -> `Ladybug err
    | Pool_shutdown -> `Pool_shutdown
    | Pool_shutdown_timeout -> `Pool_shutdown_timeout
    | Timeout -> `Timeout

  let public effect = Eta.Effect.map_error to_public_error effect

  let lift_result = function
    | Ok value -> Eta.Effect.pure value
    | Result.Error err -> Eta.Effect.fail (`Ladybug err)

  let blocking_result ?blocking_pool ?name f =
    Eta.Effect.blocking ?pool:blocking_pool ?name f |> Eta.Effect.bind lift_result

  let create ?blocking_pool ?name ?(max_size = 10) ?max_idle ?idle_lifetime
      ?max_lifetime database =
    Eta.Pool.create ?name ~kind:"ladybug" ~max_size ?max_idle ?idle_lifetime
      ?max_lifetime
      ~acquire:
        (blocking_result ?blocking_pool ~name:"ladybug.connect" (fun () ->
             Connection.connect database))
      ~release:(fun conn ->
        Eta.Effect.blocking ?pool:blocking_pool ~name:"ladybug.close" (fun () ->
            ignore (Connection.close conn)))
      ~health_check:(fun conn ->
        blocking_result ?blocking_pool ~name:"ladybug.ping" (fun () ->
            Connection.query_string conn "RETURN 1" [] |> Result.map (fun _ -> ())))
      ()
    |> public

  let with_connection t f =
    Eta.Pool.with_resource t (fun conn ->
        f conn |> Eta.Effect.map_error to_raw_error)
    |> public

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
         | `Query_error err -> Eta.Effect.fail (`Ladybug err)
         | `Timed_out -> Eta.Effect.fail `Timeout)

  let query_string ?blocking_pool ~timeout ?params t cypher =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"ladybug.query"
          (fun () -> Connection.query_string ?params conn cypher)
        |> public)

  let shutdown ?deadline t = Eta.Pool.shutdown ?deadline t |> public
  let stats = Eta.Pool.stats
end
