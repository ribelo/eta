module Q = Eta_sql
module S = Eta_sql.Sqlite
module E = Eta.Effect

let elapsed_us start =
  (Unix.gettimeofday () -. start) *. 1_000_000.0

let run rt eff = Eta.Runtime.run rt eff

let run_ok rt eff =
  match run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith
        (Format.asprintf "Eta failure: %a"
           (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
           cause)

let long_recursive_sql =
  "WITH RECURSIVE cnt(x) AS (\
   SELECT 0 UNION ALL SELECT x + 1 FROM cnt WHERE x < 100000000\
   ) SELECT sum(x) AS total FROM cnt"

let reusable_query ~blocking_pool ~timeout pool =
  Q.Eta_pool.query ~blocking_pool ~timeout pool "SELECT 1 AS one" []
  |> E.map (function
       | [ row ] -> Q.Row.int "one" row = Some 1
       | _ -> false)

let supervisor_teardown_program ~blocking_pool pool =
  let timeout = Eta.Duration.ms 5_000 in
  Eta.Supervisor.scoped {
    run =
      fun (type s) sup ->
        let open Eta.Supervisor.Scope in
        let* (_child : (s, Q.Eta_pool.error, Q.Row.t list) Eta.Supervisor.child) =
          start sup
            (lift
               (Q.Eta_pool.query ~blocking_pool ~timeout pool long_recursive_sql []))
        in
        let* () = lift (E.delay (Eta.Duration.ms 5) E.unit) in
        pure ();
  }

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking_pool =
    E.Blocking.Pool.create ~name:"sqlite-cancel-generic"
      {
        max_threads = 2;
        max_queued = 8;
        queue_policy = E.Blocking.Pool.Wait;
        shutdown_policy = E.Blocking.Pool.Drain;
      }
  in
  let config = S.memory_config () in
  Fun.protect
    ~finally:(fun () ->
      run_ok rt (E.Blocking.Pool.shutdown blocking_pool))
    (fun () ->
      let program =
        Q.Eta_pool.create ~blocking_pool ~max_size:1 config
        |> E.bind (fun pool ->
               let started = Unix.gettimeofday () in
               supervisor_teardown_program ~blocking_pool pool
               |> E.map (fun () -> elapsed_us started)
               |> E.bind (fun cancel_elapsed ->
                      reusable_query ~blocking_pool ~timeout:(Eta.Duration.ms 250)
                        pool
                      |> E.bind (fun reusable ->
                             Q.Eta_pool.shutdown pool
                             |> E.map (fun () -> (cancel_elapsed, reusable)))))
      in
      let cancel_elapsed, reusable = run_ok rt program in
      let stats = E.Blocking.Pool.stats blocking_pool in
      Printf.printf "generic_cancel_elapsed_us=%.3f\n" cancel_elapsed;
      Printf.printf "connection_reusable=%b\n" reusable;
      Printf.printf "blocking_active=%d\n" stats.active;
      Printf.printf "blocking_completed=%d\n" stats.completed)
