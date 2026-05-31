(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Types
open Dsl_backend

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

let map_duckdb_result f () =
  match f () with
  | Ok value -> Ok value
  | Result.Error err -> Result.Error (`Duckdb err)

let blocking_result ?blocking_pool ?name f =
  Eta.Effect.blocking_result ?pool:blocking_pool ?name (map_duckdb_result f)

let timed_blocking_result ?blocking_pool ~timeout ~conn ~name f =
  Eta.Effect.blocking_result_timeout ?pool:blocking_pool ~name
    ~on_cancel:(fun () -> Connection.interrupt conn)
    ~timeout ~on_timeout:`Timeout (map_duckdb_result f)

let with_connection_internal t f = Eta.Pool.with_resource t.pool f |> public

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
  with_connection_internal t (fun conn ->
      f conn |> Eta.Effect.map_error to_raw_error)

let query ?blocking_pool ~timeout t sql params =
  with_connection_internal t (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.query"
        (fun () -> Connection.query conn sql params))

let select ?blocking_pool ~timeout t query =
  with_connection_internal t (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.select"
        (fun () -> Connection.select conn query))

let returning ?blocking_pool ~timeout t query =
  with_connection_internal t (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.returning"
        (fun () -> Connection.returning conn query))

let execute ?blocking_pool ~timeout t sql params =
  with_connection_internal t (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.execute"
        (fun () -> Connection.execute conn sql params))

let execute_compiled ?blocking_pool ~timeout t query =
  with_connection_internal t (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn
        ~name:"duckdb.execute_compiled" (fun () ->
          Connection.execute_compiled conn query))

let run_schema ?blocking_pool ~timeout t schema =
  with_connection_internal t (fun conn ->
      timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.schema"
        (fun () -> Connection.run_schema conn schema))

let shutdown ?deadline t =
  let close_database =
    Eta.Effect.blocking ~name:"duckdb.close_database" (fun () ->
        ignore (Database.close t.database))
  in
  Eta.Pool.shutdown ?deadline t.pool
  |> Eta.Effect.finally close_database
  |> public

let stats t = Eta.Pool.stats t.pool
