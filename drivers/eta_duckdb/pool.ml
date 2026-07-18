(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Types
open Dsl_backend

type raw_error =
  [ `Duckdb of error
  | `Invalid_blocking_pool of string
  | `Pool_shutdown
  | `Pool_shutdown_timeout
  | `Timeout
  ]

type t = {
  database : database;
  pool : (connection, raw_error) Eta.Pool.t;
}

type nonrec error =
  | Duckdb of error
  | Invalid_blocking_pool of string
  | Pool_shutdown
  | Pool_shutdown_timeout
  | Timeout

let to_public_error = function
  | `Duckdb err -> Duckdb err
  | `Invalid_blocking_pool message -> Invalid_blocking_pool message
  | `Pool_shutdown -> Pool_shutdown
  | `Pool_shutdown_timeout -> Pool_shutdown_timeout
  | `Timeout -> Timeout

let to_raw_error = function
  | Duckdb err -> `Duckdb err
  | Invalid_blocking_pool message -> `Invalid_blocking_pool message
  | Pool_shutdown -> `Pool_shutdown
  | Pool_shutdown_timeout -> `Pool_shutdown_timeout
  | Timeout -> `Timeout

let public eff = Eta.Effect.map_error to_public_error eff

module Driver_blocking = Eta_sql_driver.Make (struct
  type driver_error = Types.error
  type nonrec error = raw_error

  let map_error (err : driver_error) : error = `Duckdb err

  let detach_started_error =
    `Invalid_blocking_pool
      "Eta_duckdb.Pool: Detach_started blocking pools cannot be used with leased connections"
end)

let blocking_result = Driver_blocking.blocking_result

let timed_blocking_result ?blocking_pool ~timeout ~conn ~name f =
  Driver_blocking.leased_blocking_result_timeout ?blocking_pool ~name
    ~on_cancel:(fun () -> Connection.interrupt conn)
    ~timeout ~on_timeout:`Timeout f

let with_connection_internal t f = Eta.Pool.with_resource t.pool f |> public

let close_database_on_create_failure ?blocking_pool release_on_create_failure
    database =
  if !release_on_create_failure then
    blocking_result ?blocking_pool ~name:"duckdb.close_database" (fun () ->
        Database.close database)
  else Eta.Effect.unit

let create ?blocking_pool ?name ?(max_size = 10) ?max_idle ?idle_lifetime
    ?max_lifetime config =
  Eta.Effect.sync (fun () -> ref true)
  |> Eta.Effect.bind (fun release_on_create_failure ->
         Eta.Effect.with_scope
           (Eta.Effect.acquire_release
              ~acquire:
                (blocking_result ?blocking_pool ~name:"duckdb.open" (fun () ->
                     Database.open_ config))
              ~release:(fun database ->
                close_database_on_create_failure ?blocking_pool
                  release_on_create_failure database)
           |> Eta.Effect.bind (fun database ->
                  Eta.Pool.create ?name ~kind:"duckdb" ~max_size ?max_idle
                    ?idle_lifetime ?max_lifetime
                    ~acquire:
                      (blocking_result ?blocking_pool ~name:"duckdb.connect"
                         (fun () -> Connection.connect database))
                    ~release:(fun conn ->
                      Eta_blocking.run ?pool:blocking_pool
                        ~name:"duckdb.disconnect" (fun () ->
                          ignore (Connection.close conn)))
                    ~health_check:(fun conn ->
                      blocking_result ?blocking_pool ~name:"duckdb.ping"
                        (fun () ->
                          match Connection.query conn "SELECT 1" [] with
                          | Ok _ -> Ok ()
                          | Result.Error _ as err -> err))
                    ()
                  |> Eta.Effect.map (fun pool ->
                         (* Pool.shutdown owns the parent database after this
                            point; before it, the scoped finalizer closes
                            database handles lost to creation failure or
                            cancellation. *)
                         release_on_create_failure := false;
                         { database; pool }))))
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
    blocking_result ~name:"duckdb.close_database" (fun () ->
        Database.close t.database)
  in
  (* The database owns every leased DuckDB connection. If Eta.Pool.shutdown
     times out, active leases may still be running, so closing the parent
     database here would invalidate those handles under their callers. *)
  Eta.Pool.shutdown ?deadline t.pool
  |> Eta.Effect.bind (fun () -> close_database)
  |> public

let stats t = Eta.Pool.stats t.pool
