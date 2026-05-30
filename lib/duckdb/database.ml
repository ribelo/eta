(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

open Types

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
