module Q = Eta_sql
module S = Eta_sql.Sqlite
module E = Eta.Effect

let run_ok rt eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith
        (Format.asprintf "Eta failure: %a"
           (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
           cause)

let temp_db_config () =
  let path = Filename.temp_file "eta-sqlite-busy-" ".db" in
  Sys.remove path;
  ( path,
    {
      (S.default_config path) with
      busy_timeout_ms = Some 1;
      journal_mode = None;
      synchronous = Some `Normal;
    } )

let sql_effect pool name f =
  E.blocking ~pool ~name (fun () -> f ())
  |> E.bind (function
       | Ok value -> E.pure value
       | Error err -> E.fail (`Sql err))

let execute pool conn sql params =
  sql_effect pool "sqlite.busy.execute" (fun () -> Q.Connection.execute conn sql params)

let execute_script pool conn sql =
  sql_effect pool "sqlite.busy.exec_script" (fun () -> Q.Connection.execute_script conn sql)

let query_count pool conn =
  sql_effect pool "sqlite.busy.query_count" (fun () ->
      match Q.Connection.query conn "SELECT COUNT(*) AS count FROM items" [] with
      | Ok [ row ] -> (
          match Q.Row.int "count" row with
          | Some count -> Ok count
          | None -> Error (Q.Decode_error { operation = "count"; message = "missing count" }))
      | Ok _ -> Error (Q.Decode_error { operation = "count"; message = "unexpected row count" })
      | Error _ as err -> err)

let is_busy = function
  | `Sql (Q.Sqlite err) -> S.rc_equal err.S.code S.busy
  | _ -> false

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking_pool =
    E.Blocking.Pool.create ~name:"sqlite-busy"
      {
        max_threads = 4;
        max_queued = 32;
        queue_policy = E.Blocking.Pool.Wait;
        shutdown_policy = E.Blocking.Pool.Drain;
      }
  in
  let path, config = temp_db_config () in
  let owner = S.open_with_config config in
  Fun.protect
    ~finally:(fun () ->
      ignore (S.rollback_result owner);
      ignore (S.close owner);
      run_ok rt (E.Blocking.Pool.shutdown blocking_pool);
      if Sys.file_exists path then Sys.remove path)
    (fun () ->
      S.exec owner "CREATE TABLE items (id INTEGER PRIMARY KEY)";
      S.begin_transaction ~mode:S.Immediate owner;
      let attempts = ref 0 in
      let program =
        Q.Eta_pool.create ~max_size:1 config
        |> E.bind (fun pool ->
               let insert =
                 Q.Eta_pool.with_connection pool (fun conn ->
                     E.sync (fun () -> incr attempts)
                     |> E.bind (fun () ->
                            execute blocking_pool conn
                              "INSERT INTO items (id) VALUES (?)"
                              [ Q.Value.int 1 ]))
               in
               let retrying_insert =
                 E.retry
                   (Eta.Schedule.both (Eta.Schedule.recurs 20)
                      (Eta.Schedule.spaced (Eta.Duration.ms 5)))
                   is_busy insert
               in
               let releaser =
                 E.delay (Eta.Duration.ms 30)
                   (E.sync (fun () -> S.commit owner))
               in
               E.par retrying_insert releaser
               |> E.bind (fun (rows_affected, ()) ->
                      Q.Eta_pool.with_connection pool (fun conn ->
                          query_count blocking_pool conn)
                      |> E.bind (fun count ->
                             Q.Eta_pool.shutdown pool
                             |> E.map (fun () -> (rows_affected, count)))))
      in
      let rows_affected, final_count = run_ok rt program in
      let stats = E.Blocking.Pool.stats blocking_pool in
      Printf.printf "busy_attempts=%d\n" !attempts;
      Printf.printf "rows_affected=%d\n" rows_affected;
      Printf.printf "final_count=%d\n" final_count;
      Printf.printf "blocking_active=%d\n" stats.active;
      Printf.printf "blocking_completed=%d\n" stats.completed)
