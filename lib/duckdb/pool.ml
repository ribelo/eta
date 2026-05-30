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

  let select ?blocking_pool ~timeout t query =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.select"
          (fun () -> Connection.select conn query)
        |> public)

  let returning ?blocking_pool ~timeout t query =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.returning"
          (fun () -> Connection.returning conn query)
        |> public)

  let execute ?blocking_pool ~timeout t sql params =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.execute"
          (fun () -> Connection.execute conn sql params)
        |> public)

  let execute_compiled ?blocking_pool ~timeout t query =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn
          ~name:"duckdb.execute_compiled" (fun () ->
            Connection.execute_compiled conn query)
        |> public)

  let run_schema ?blocking_pool ~timeout t schema =
    with_connection t (fun conn ->
        timed_blocking_result ?blocking_pool ~timeout ~conn ~name:"duckdb.schema"
          (fun () -> Connection.run_schema conn schema)
        |> public)

  let shutdown ?deadline t =
    Eta.Pool.shutdown ?deadline t.pool
    |> Eta.Effect.bind (fun () ->
           Eta.Effect.blocking ~name:"duckdb.close_database" (fun () ->
               ignore (Database.close t.database)))
    |> public

  let stats t = Eta.Pool.stats t.pool
