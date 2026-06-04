(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Types
open Connection
open Dsl_backend
open Compiled_ops

type raw_error =
  [ `Turso of error
  | `Invalid_blocking_pool of string
  | `Pool_shutdown
  | `Pool_shutdown_timeout
  | `Timeout
  ]
type t = (db, raw_error) Eta.Pool.t

type nonrec error : immutable_data =
  | Turso of error
  | Invalid_blocking_pool of string
  | Pool_shutdown
  | Pool_shutdown_timeout
  | Timeout

let pp_error ppf = function
  | Turso err -> pp_turso_error ppf err
  | Invalid_blocking_pool message ->
      Format.fprintf ppf "invalid blocking pool: %s" message
  | Pool_shutdown -> Format.pp_print_string ppf "pool shutdown"
  | Pool_shutdown_timeout -> Format.pp_print_string ppf "pool shutdown timeout"
  | Timeout -> Format.pp_print_string ppf "timeout"

let to_public_error = function
  | `Turso err -> Turso err
  | `Invalid_blocking_pool message -> Invalid_blocking_pool message
  | `Pool_shutdown -> Pool_shutdown
  | `Pool_shutdown_timeout -> Pool_shutdown_timeout
  | `Timeout -> Timeout

let public effect = Eta.Effect.map_error to_public_error effect

module Driver_blocking = Eta_sql_driver.Make (struct
  type driver_error = Types.error
  type nonrec error = raw_error

  let map_error (err : driver_error) : error = `Turso err

  let detach_started_error =
    `Invalid_blocking_pool
      "Eta_turso.Pool: Detach_started blocking pools cannot be used with leased connections"
end)

let blocking_result = Driver_blocking.blocking_result

let leased_blocking_result ?blocking_pool ?name db f =
  Driver_blocking.leased_blocking_result ?blocking_pool ?name
    ~on_cancel:(fun () -> interrupt db)
    f

let acquire ?blocking_pool config =
  blocking_result ?blocking_pool ~name:"turso.open" (fun () -> open_ config)

let release ?blocking_pool db =
  Eta.Effect.blocking ?pool:blocking_pool ~name:"turso.close" (fun () ->
      ignore (close db))

let health_check ?blocking_pool db =
  blocking_result ?blocking_pool ~name:"turso.ping" (fun () ->
      match query db "SELECT 1" [] with
      | Ok _ -> Ok ()
      | Result.Error _ as err -> err)

let create ?blocking_pool ?name ?(max_size = 10) ?max_idle ?idle_lifetime
    ?max_lifetime config =
  Eta.Pool.create ?name ~kind:"turso" ~max_size ?max_idle ?idle_lifetime
    ?max_lifetime ~acquire:(acquire ?blocking_pool config)
    ~release:(release ?blocking_pool)
    ~health_check:(health_check ?blocking_pool) ()
  |> public

let with_db_internal t f =
  Eta.Pool.with_resource t f |> public

let with_db t f =
  with_db_internal t (fun db ->
      f db |> Eta.Effect.map_error (function
        | Turso err -> `Turso err
        | Invalid_blocking_pool message -> `Invalid_blocking_pool message
        | Pool_shutdown -> `Pool_shutdown
        | Pool_shutdown_timeout -> `Pool_shutdown_timeout
        | Timeout -> `Timeout))

let query ?blocking_pool t sql params =
  with_db_internal t (fun db ->
      leased_blocking_result ?blocking_pool ~name:"turso.query" db (fun () ->
          query db sql params))

let select ?blocking_pool t query =
  with_db_internal t (fun db ->
      leased_blocking_result ?blocking_pool ~name:"turso.select" db (fun () ->
          select db query))

let returning ?blocking_pool t query =
  with_db_internal t (fun db ->
      leased_blocking_result ?blocking_pool ~name:"turso.returning" db (fun () ->
          returning db query))

let execute ?blocking_pool t sql params =
  with_db_internal t (fun db ->
      leased_blocking_result ?blocking_pool ~name:"turso.execute" db (fun () ->
          execute db sql params))

let execute_compiled ?blocking_pool t query =
  with_db_internal t (fun db ->
      leased_blocking_result ?blocking_pool ~name:"turso.execute_compiled" db (fun () ->
          execute_compiled db query))

let run_schema ?blocking_pool t schema =
  with_db_internal t (fun db ->
      leased_blocking_result ?blocking_pool ~name:"turso.schema" db (fun () ->
          run_schema db schema))

let shutdown ?deadline t = Eta.Pool.shutdown ?deadline t |> public
let stats = Eta.Pool.stats
