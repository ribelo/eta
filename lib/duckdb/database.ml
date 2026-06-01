(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Types

type t = database

let validate_config config =
  match config.threads with
  | Some threads when threads <= 0 ->
      Result.Error
        (Invalid_value "Eta_duckdb.Database.open_: threads must be positive")
  | Some _ | None -> Ok ()

let close_after_open_failure (db : database) =
  if not db.closed then (
    db.closed <- true;
    try raw_close_database db.raw with _ -> ())

let unlink_connection (db : database) (conn : connection) =
  db.connections <- List.filter (fun live -> live != conn) db.connections

let close_connection (conn : connection) =
  if conn.closed then Ok ()
  else
    match wrap "disconnect" (fun () -> raw_disconnect conn.raw) with
    | Ok () ->
        conn.closed <- true;
        unlink_connection conn.database conn;
        Ok ()
    | Result.Error _ as err -> err

let rec close_connections = function
  | [] -> Ok ()
  | conn :: rest -> (
      match close_connection conn with
      | Ok () -> close_connections rest
      | Result.Error _ as err -> err)

let open_ config =
  match validate_config config with
  | Result.Error _ as err -> err
  | Ok () ->
      wrap "open" @@ fun () ->
      let path = Option.value config.path ~default:"" in
      let db = { raw = raw_open path; closed = false; connections = [] } in
      (try
         (match config.threads with
         | None -> ()
         | Some threads ->
             let conn =
               { database = db; raw = raw_connect db.raw; closed = false }
             in
             Fun.protect
               ~finally:(fun () ->
                 conn.closed <- true;
                 raw_disconnect conn.raw)
               (fun () ->
                 raw_exec_script conn.raw
                   ("PRAGMA threads=" ^ string_of_int threads)));
         db
       with exn ->
         let bt = Printexc.get_raw_backtrace () in
         close_after_open_failure db;
         Printexc.raise_with_backtrace exn bt)

let open_memory () = open_ { path = None; threads = None }

let close db =
  if_database_open db @@ fun () ->
  match close_connections db.connections with
  | Result.Error _ as err -> err
  | Ok () -> (
      match wrap "close database" (fun () -> raw_close_database db.raw) with
      | Ok () ->
          db.closed <- true;
          Ok ()
      | Result.Error _ as err -> err)
