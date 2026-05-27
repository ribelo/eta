module S = Eta_sql.Sqlite
module E = Eta.Effect

type query_event =
  | Query_ok
  | Query_error of int * string
  | Interrupt_sent

let elapsed_us start =
  Mtime.Span.to_uint64_ns (Mtime_clock.count start)
  |> Int64.to_float
  |> fun ns -> ns /. 1_000.0

let run_ok rt eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith
        (Format.asprintf "Eta failure: %a"
           (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
           cause)

let setup_locked_pair () =
  let path = Filename.temp_file "eta-sqlite-cancel-" ".db" in
  Sys.remove path;
  let config =
    {
      (S.default_config path) with
      busy_timeout_ms = Some 80;
      journal_mode = None;
      synchronous = None;
    }
  in
  let owner = S.open_with_config config in
  let contender = S.open_with_config config in
  S.exec owner "CREATE TABLE items (id INTEGER PRIMARY KEY)";
  S.begin_transaction ~mode:S.Immediate owner;
  (path, owner, contender)

let close_locked_pair (path, owner, contender) =
  ignore (S.rollback_result owner);
  ignore (S.close contender);
  ignore (S.close owner);
  if Sys.file_exists path then Sys.remove path

let naive_timeout_probe rt pool =
  let fixture = setup_locked_pair () in
  Fun.protect
    ~finally:(fun () -> close_locked_pair fixture)
    (fun () ->
      let _, _, contender = fixture in
      let started = Mtime_clock.counter () in
      let result =
        Eta.Runtime.run rt
          (E.blocking ~pool ~name:"sqlite.cancel.naive_busy" (fun () ->
               S.exec_result contender "INSERT INTO items (id) VALUES (1)")
          |> E.timeout (Eta.Duration.ms 5))
      in
      let elapsed = elapsed_us started in
      let timed_out = match result with Eta.Exit.Error _ -> true | Eta.Exit.Ok _ -> false in
      (elapsed, timed_out))

let long_recursive_sql =
  "WITH RECURSIVE cnt(x) AS (\
   SELECT 0 UNION ALL SELECT x + 1 FROM cnt WHERE x < 100000000\
   ) SELECT sum(x) FROM cnt"

let recursive_query db =
  match S.prepare_result db long_recursive_sql with
  | Error err -> Error err
  | Ok stmt ->
      Fun.protect
        ~finally:(fun () -> ignore (S.finalize stmt))
        (fun () ->
          let rc = S.step stmt in
          if S.rc_equal rc S.row then (
            ignore (S.column_int64 stmt 0);
            let drain = S.step stmt in
            if S.rc_equal drain S.done_ then
              Ok ()
            else
              Error
                {
                  S.operation = "recursive drain";
                  code = drain;
                  message = S.error_message db;
                })
          else
            Error
              {
                S.operation = "recursive step";
                code = rc;
                message = S.error_message db;
              })

let interrupt_probe rt pool =
  let db = S.open_memory () in
  Fun.protect
    ~finally:(fun () -> ignore (S.close db))
    (fun () ->
      let started = Mtime_clock.counter () in
      let program =
        E.all
          [
            (E.blocking ~pool ~name:"sqlite.cancel.recursive" (fun () ->
                 recursive_query db)
            |> E.map (function
                 | Ok () -> Query_ok
                 | Error err ->
                     Query_error (S.rc_code err.S.code, err.S.message)));
            (E.delay (Eta.Duration.ms 5)
               (E.sync (fun () ->
                    S.interrupt db;
                    Interrupt_sent)));
          ]
      in
      let events = run_ok rt program in
      let elapsed = elapsed_us started in
      let reusable =
        match S.query_one_int_result db "SELECT 1" with
        | Ok 1 -> true
        | _ -> false
      in
      (elapsed, events, reusable))

let has_interrupt_error =
  List.exists
    (function
      | Query_error (code, _) -> code = S.rc_code S.interrupt_
      | _ -> false)

let has_interrupt_sent =
  List.exists (function Interrupt_sent -> true | _ -> false)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let pool =
    E.Blocking.Pool.create ~name:"sqlite-cancel"
      {
        max_threads = 2;
        max_queued = 8;
        queue_policy = E.Blocking.Pool.Wait;
        shutdown_policy = E.Blocking.Pool.Drain;
      }
  in
  let naive_elapsed, naive_timed_out = naive_timeout_probe rt pool in
  let interrupt_elapsed, events, reusable = interrupt_probe rt pool in
  let stats_before_shutdown = E.Blocking.Pool.stats pool in
  run_ok rt (E.Blocking.Pool.shutdown pool);
  Printf.printf "naive_timeout_elapsed_us=%.3f\n" naive_elapsed;
  Printf.printf "naive_timeout_observed=%b\n" naive_timed_out;
  Printf.printf "interrupt_elapsed_us=%.3f\n" interrupt_elapsed;
  Printf.printf "interrupt_sent=%b\n" (has_interrupt_sent events);
  Printf.printf "query_interrupted=%b\n" (has_interrupt_error events);
  Printf.printf "connection_reusable=%b\n" reusable;
  Printf.printf "blocking_active=%d\n" stats_before_shutdown.active;
  Printf.printf "blocking_completed=%d\n" stats_before_shutdown.completed
