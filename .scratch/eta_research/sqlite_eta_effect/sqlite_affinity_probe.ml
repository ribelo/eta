module S = Eta_sql.Sqlite
module E = Eta.Effect

let iterations = 100_000
let interleave_iterations = 20_000
let long_overlap_iterations = 2_000

type gate = {
  mutex : Mutex.t;
  condition : Condition.t;
  mutable ready : bool;
  mutable release : bool;
}

let make_gate () =
  { mutex = Mutex.create (); condition = Condition.create (); ready = false; release = false }

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

let check_rc db operation rc =
  match S.check db ~operation rc with
  | Ok () -> ()
  | Error err -> failwith (Format.asprintf "%a" S.pp_error err)

let setup_db () =
  let db = S.open_memory () in
  S.exec_script db
    "CREATE TABLE items (id INTEGER PRIMARY KEY, value INTEGER NOT NULL);\
     INSERT INTO items (id, value) VALUES (1, 10), (2, 20);";
  db

let setup_stmt db = S.prepare db "SELECT value FROM items WHERE id = ?"

let step_pk db stmt id =
  check_rc db "reset" (S.reset stmt);
  check_rc db "clear bindings" (S.clear_bindings stmt);
  check_rc db "bind id" (S.bind_int stmt 1 id);
  let rc = S.step stmt in
  if not (S.rc_equal rc S.row) then (
    let err = { S.operation = "step row"; code = rc; message = S.error_message db } in
    failwith (Format.asprintf "%a" S.pp_error err));
  let value = S.column_int stmt 0 in
  let rc = S.step stmt in
  if not (S.rc_equal rc S.done_) then (
    let err = { S.operation = "step done"; code = rc; message = S.error_message db } in
    failwith (Format.asprintf "%a" S.pp_error err));
  value

let worker_loop_n pool db stmt ~iterations ~id ~expected ~name =
  let rec loop remaining ok_count =
    if remaining = 0 then
      E.pure ok_count
    else
      E.blocking ~pool ~name (fun () ->
          try Ok (step_pk db stmt id) with exn -> Error (Printexc.to_string exn))
      |> E.bind (function
           | Ok value when value = expected -> loop (remaining - 1) (ok_count + 1)
           | Ok value ->
               E.sync (fun () ->
                   failwith
                     (Printf.sprintf "unexpected value for id %d: %d" id value))
           | Error reason -> E.sync (fun () -> failwith reason))
  in
  loop iterations 0

let signal_ready gate =
  Mutex.lock gate.mutex;
  gate.ready <- true;
  Condition.broadcast gate.condition;
  Mutex.unlock gate.mutex

let wait_until_ready gate =
  E.blocking ~name:"sqlite.affinity.wait-ready" (fun () ->
      Mutex.lock gate.mutex;
      while not gate.ready do
        Condition.wait gate.condition gate.mutex
      done;
      Mutex.unlock gate.mutex;
      Ok ())
  |> E.bind (function Ok () -> E.unit | Error err -> E.sync (fun () -> failwith err))

let release_gate gate =
  E.sync (fun () ->
      Mutex.lock gate.mutex;
      gate.release <- true;
      Condition.broadcast gate.condition;
      Mutex.unlock gate.mutex)

let wait_for_release gate =
  Mutex.lock gate.mutex;
  while not gate.release do
    Condition.wait gate.condition gate.mutex
  done;
  Mutex.unlock gate.mutex

let held_open_probe pool db =
  let gate = make_gate () in
  let holder = S.prepare db "SELECT value FROM items ORDER BY id" in
  let contender = setup_stmt db in
  let holder_eff =
    E.blocking ~pool ~name:"sqlite.affinity.held-open" (fun () ->
        try
          check_rc db "held reset" (S.reset holder);
          let rc = S.step holder in
          if not (S.rc_equal rc S.row) then
            failwith "held statement did not produce first row";
          ignore (S.column_int holder 0);
          signal_ready gate;
          wait_for_release gate;
          let rec drain count =
            let rc = S.step holder in
            if S.rc_equal rc S.row then
              drain (count + 1)
            else if S.rc_equal rc S.done_ then
              count
            else
              failwith ("held drain failed: " ^ S.error_message db)
          in
          Ok (drain 1)
        with exn -> Error (Printexc.to_string exn))
    |> E.bind (function
         | Ok rows -> E.pure rows
         | Error reason -> E.sync (fun () -> failwith reason))
  in
  let contender_eff =
    wait_until_ready gate
    |> E.bind (fun () ->
           worker_loop_n pool db contender ~iterations:interleave_iterations ~id:1
             ~expected:10 ~name:"sqlite.affinity.held-contender")
    |> E.bind (fun count -> release_gate gate |> E.map (fun () -> count))
  in
  E.all [ holder_eff; contender_eff ]
  |> E.map (function
       | [ holder_rows; contender_ok ] -> (holder_rows, contender_ok)
       | _ -> failwith "unexpected held-open probe shape")
  |> E.map (fun result ->
         ignore (S.finalize holder);
         ignore (S.finalize contender);
         result)

let long_step_overlap_probe pool db =
  let gate = make_gate () in
  let long_stmt =
    S.prepare db
      "WITH RECURSIVE cnt(x) AS (\
       SELECT 0 UNION ALL SELECT x + 1 FROM cnt WHERE x < 200000\
       ) SELECT sum(x) FROM cnt"
  in
  let short_stmt = setup_stmt db in
  let long_eff =
    E.blocking ~pool ~name:"sqlite.affinity.long-step" (fun () ->
        try
          signal_ready gate;
          let rc = S.step long_stmt in
          if not (S.rc_equal rc S.row) then
            failwith ("long step did not return row: " ^ S.error_message db);
          let sum = S.column_int64 long_stmt 0 in
          let rc = S.step long_stmt in
          if not (S.rc_equal rc S.done_) then
            failwith ("long step did not finish: " ^ S.error_message db);
          Ok sum
        with exn -> Error (Printexc.to_string exn))
    |> E.bind (function
         | Ok sum -> E.pure sum
         | Error reason -> E.sync (fun () -> failwith reason))
  in
  let short_eff =
    wait_until_ready gate
    |> E.bind (fun () ->
           worker_loop_n pool db short_stmt ~iterations:long_overlap_iterations ~id:2
             ~expected:20 ~name:"sqlite.affinity.long-contender")
    |> E.map Int64.of_int
  in
  E.all [ long_eff; short_eff ]
  |> E.map (function
       | [ sum; short_ok ] -> (sum, Int64.to_int short_ok)
       | _ -> failwith "unexpected long-overlap probe shape")
  |> E.map (fun result ->
         ignore (S.finalize long_stmt);
         ignore (S.finalize short_stmt);
         result)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let pool =
    E.Blocking.Pool.create ~name:"sqlite-affinity"
      {
        max_threads = 4;
        max_queued = 256;
        queue_policy = E.Blocking.Pool.Wait;
        shutdown_policy = E.Blocking.Pool.Drain;
      }
  in
  let db = setup_db () in
  let stmt_a = setup_stmt db in
  let stmt_b = setup_stmt db in
  Fun.protect
    ~finally:(fun () ->
      ignore (S.finalize stmt_a);
      ignore (S.finalize stmt_b);
      ignore (S.close db);
      run_ok rt (E.Blocking.Pool.shutdown pool))
    (fun () ->
      let started = Mtime_clock.counter () in
      let counts =
        run_ok rt
          (E.all
             [
               worker_loop_n pool db stmt_a ~iterations ~id:1 ~expected:10
                 ~name:"sqlite.affinity.pk-a";
               worker_loop_n pool db stmt_b ~iterations ~id:2 ~expected:20
                 ~name:"sqlite.affinity.pk-b";
             ])
      in
      let held_rows, held_contender_ok = run_ok rt (held_open_probe pool db) in
      let long_sum, long_contender_ok = run_ok rt (long_step_overlap_probe pool db) in
      let elapsed = elapsed_us started in
      let reusable =
        match S.query_one_int_result db "SELECT 1" with
        | Ok 1 -> true
        | _ -> false
      in
      let stats = E.Blocking.Pool.stats pool in
      let total_ok = List.fold_left ( + ) 0 counts in
      Printf.printf "affinity_iterations_per_fiber=%d\n" iterations;
      Printf.printf "affinity_total_ok=%d\n" total_ok;
      Printf.printf "held_open_rows=%d\n" held_rows;
      Printf.printf "held_open_contender_ok=%d\n" held_contender_ok;
      Printf.printf "long_step_sum=%Ld\n" long_sum;
      Printf.printf "long_step_contender_ok=%d\n" long_contender_ok;
      Printf.printf "affinity_elapsed_us=%.3f\n" elapsed;
      Printf.printf "connection_reusable=%b\n" reusable;
      Printf.printf "blocking_active=%d\n" stats.active;
      Printf.printf "blocking_completed=%d\n" stats.completed)
