module Q = Sql
module S = Sqlite
module E = Eta.Effect

type event =
  | Tx_internal_count of int
  | Observer_count of int
  | Final_count of int

let run_ok rt eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith
        (Format.asprintf "Eta failure: %a"
           (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
           cause)

let temp_db_config () =
  let path = Filename.temp_file "eta-sqlite-tx-" ".db" in
  Sys.remove path;
  ( path,
    {
      (S.default_config path) with
      busy_timeout_ms = Some 200;
      journal_mode = None;
      synchronous = Some `Normal;
    } )

let sql_effect pool name f =
  E.blocking ~pool ~name (fun () -> f ())
  |> E.bind (function
       | Ok value -> E.pure value
       | Error err -> E.fail (`Sql err))

let execute_script pool conn sql =
  sql_effect pool "sqlite.tx.exec_script" (fun () -> Q.Connection.execute_script conn sql)

let execute pool conn sql params =
  sql_effect pool "sqlite.tx.execute" (fun () -> Q.Connection.execute conn sql params)

let query_count pool conn =
  sql_effect pool "sqlite.tx.query_count" (fun () ->
      match Q.Connection.query conn "SELECT COUNT(*) AS count FROM items" [] with
      | Ok [ row ] -> (
          match Q.Row.int "count" row with
          | Some count -> Ok count
          | None -> Error (Q.Decode_error { operation = "count"; message = "missing count" }))
      | Ok _ -> Error (Q.Decode_error { operation = "count"; message = "unexpected row count" })
      | Error _ as err -> err)

let begin_tx pool conn =
  sql_effect pool "sqlite.tx.begin" (fun () -> Q.Connection.begin_transaction conn)

let commit pool conn =
  sql_effect pool "sqlite.tx.commit" (fun () -> Q.Connection.commit conn)

let rollback pool conn =
  sql_effect pool "sqlite.tx.rollback" (fun () -> Q.Connection.rollback conn)

let with_tx pool conn body =
  let committed = ref false in
  E.scoped
    (E.acquire_release
       ~acquire:(begin_tx pool conn)
       ~release:(fun () -> if !committed then E.unit else rollback pool conn)
    |> E.bind (fun () ->
           body ()
           |> E.bind (fun value ->
                  commit pool conn
                  |> E.map (fun () ->
                         committed := true;
                         value))))

let option_int = Option.fold ~none:"none" ~some:string_of_int

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking_pool =
    E.Blocking.Pool.create ~name:"sqlite-tx"
      {
        max_threads = 4;
        max_queued = 32;
        queue_policy = E.Blocking.Pool.Wait;
        shutdown_policy = E.Blocking.Pool.Drain;
      }
  in
  let path, config = temp_db_config () in
  Fun.protect
    ~finally:(fun () ->
      run_ok rt (E.Blocking.Pool.shutdown blocking_pool);
      if Sys.file_exists path then Sys.remove path)
    (fun () ->
      let program =
        Q.Eta_pool.create ~max_size:2 config
        |> E.bind (fun pool ->
               Q.Eta_pool.with_connection pool (fun conn ->
                   execute_script blocking_pool conn
                     "CREATE TABLE items (id INTEGER PRIMARY KEY)")
               |> E.bind (fun () ->
                      let tx =
                        Q.Eta_pool.with_connection pool (fun conn ->
                            with_tx blocking_pool conn (fun () ->
                                execute blocking_pool conn
                                  "INSERT INTO items (id) VALUES (?)"
                                  [ Q.Value.int 1 ]
                                |> E.bind (fun _ ->
                                       query_count blocking_pool conn
                                       |> E.bind (fun count ->
                                              E.delay (Eta.Duration.ms 30)
                                                (E.pure (Tx_internal_count count))))))
                      in
                      let observer =
                        E.delay (Eta.Duration.ms 5)
                          (Q.Eta_pool.with_connection pool (fun conn ->
                               query_count blocking_pool conn
                               |> E.map (fun count -> Observer_count count)))
                      in
                      E.par tx observer)
               |> E.bind (fun (tx_event, observer_event) ->
                      Q.Eta_pool.with_connection pool (fun conn ->
                          query_count blocking_pool conn
                          |> E.map (fun count ->
                                 [ tx_event; observer_event; Final_count count ]))
                      |> E.bind (fun events ->
                             Q.Eta_pool.shutdown pool |> E.map (fun () -> events))))
      in
      let events = run_ok rt program in
      let tx_internal =
        List.find_map
          (function Tx_internal_count count -> Some count | _ -> None)
          events
      in
      let observer =
        List.find_map (function Observer_count count -> Some count | _ -> None) events
      in
      let final =
        List.find_map (function Final_count count -> Some count | _ -> None) events
      in
      let stats = E.Blocking.Pool.stats blocking_pool in
      Printf.printf "tx_internal_count=%s\n" (option_int tx_internal);
      Printf.printf "observer_count_during_tx=%s\n" (option_int observer);
      Printf.printf "final_count_after_commit=%s\n" (option_int final);
      Printf.printf "blocking_active=%d\n" stats.active;
      Printf.printf "blocking_completed=%d\n" stats.completed)
