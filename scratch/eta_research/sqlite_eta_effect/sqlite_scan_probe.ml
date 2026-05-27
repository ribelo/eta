module S = Eta_sql.Sqlite
module E = Eta.Effect

let rows = 200_000
let batch_size = 1_024
let heartbeat_interval = 0.001

type scan_result = {
  count : int;
  sum : int;
}

type step_result =
  | Row of int
  | Done

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
    (Printf.sprintf
       "PRAGMA temp_store = MEMORY;\
        CREATE TABLE items (id INTEGER PRIMARY KEY, value INTEGER NOT NULL);\
        WITH RECURSIVE cnt(x) AS (\
          SELECT 1 UNION ALL SELECT x + 1 FROM cnt WHERE x < %d\
        ) INSERT INTO items (id, value) SELECT x, x FROM cnt"
       rows);
  db

let prepare_scan db = S.prepare db "SELECT value FROM items ORDER BY id"

let step_one db stmt =
  let rc = S.step stmt in
  if S.rc_equal rc S.row then
    Row (S.column_int stmt 0)
  else if S.rc_equal rc S.done_ then
    Done
  else
    failwith
      (Format.asprintf "scan step: %a" S.pp_error
         { S.operation = "scan step"; code = rc; message = S.error_message db })

let scan_same_domain db =
  let stmt = prepare_scan db in
  Fun.protect
    ~finally:(fun () -> ignore (S.finalize stmt))
    (fun () ->
      let rec loop count sum =
        match step_one db stmt with
        | Row value -> loop (count + 1) (sum + value)
        | Done -> { count; sum }
      in
      loop 0 0)

let scan_materialized_blocking pool db =
  let stmt = prepare_scan db in
  E.blocking ~pool ~name:"sqlite.scan.materialized" (fun () ->
      try
        let rec loop acc =
          match step_one db stmt with
          | Row value -> loop (value :: acc)
          | Done -> Ok acc
        in
        loop []
      with exn -> Error (Printexc.to_string exn))
  |> E.bind (function
       | Error reason ->
           ignore (S.finalize stmt);
           E.sync (fun () -> failwith reason)
       | Ok values ->
           ignore (S.finalize stmt);
           E.sync (fun () ->
               List.fold_left
                 (fun { count; sum } value ->
                   { count = count + 1; sum = sum + value })
                 { count = 0; sum = 0 } values))

let scan_per_row_blocking pool db =
  let stmt = prepare_scan db in
  let rec loop count sum =
    E.blocking ~pool ~name:"sqlite.scan.per-row" (fun () ->
        try Ok (step_one db stmt) with exn -> Error (Printexc.to_string exn))
    |> E.bind (function
         | Error reason ->
             ignore (S.finalize stmt);
             E.sync (fun () -> failwith reason)
         | Ok (Row value) -> loop (count + 1) (sum + value)
         | Ok Done ->
             ignore (S.finalize stmt);
             E.pure { count; sum })
  in
  loop 0 0

let step_batch db stmt =
  let rec loop remaining count sum done_ =
    if done_ || remaining = 0 then
      (done_, count, sum)
    else
      match step_one db stmt with
      | Row value -> loop (remaining - 1) (count + 1) (sum + value) false
      | Done -> loop 0 count sum true
  in
  loop batch_size 0 0 false

let scan_batch_blocking pool db =
  let stmt = prepare_scan db in
  let rec loop count sum =
    E.blocking ~pool ~name:"sqlite.scan.batch" (fun () ->
        try Ok (step_batch db stmt) with exn -> Error (Printexc.to_string exn))
    |> E.bind (function
         | Error reason ->
             ignore (S.finalize stmt);
             E.sync (fun () -> failwith reason)
         | Ok (done_, batch_count, batch_sum) ->
             let count = count + batch_count in
             let sum = sum + batch_sum in
             if done_ then (
               ignore (S.finalize stmt);
               E.pure { count; sum })
             else
               loop count sum)
  in
  loop 0 0

let percentile values pct =
  match values with
  | [] -> 0.0
  | values ->
      let sorted = Array.of_list values in
      Array.sort Float.compare sorted;
      let index =
        int_of_float
          (ceil ((float_of_int (Array.length sorted) *. pct) /. 100.0) -. 1.0)
      in
      sorted.(max 0 (min (Array.length sorted - 1) index))

let max_float values = List.fold_left max 0.0 values

let measure ~clock ~pool ~label f =
  Gc.compact ();
  let before_gc = Gc.quick_stat () in
  let before_bytes = Gc.allocated_bytes () in
  let before_completed = (E.Blocking.Pool.stats pool).completed in
  let samples = ref [] in
  let running = ref true in
  let result = ref None in
  let wall_ms = ref 0.0 in
  Eio.Fiber.both
    (fun () ->
      let rec loop last =
        if !running then (
          Eio.Time.sleep clock heartbeat_interval;
          let now = Unix.gettimeofday () in
          let delay_us = ((now -. last) -. heartbeat_interval) *. 1_000_000.0 in
          samples := max 0.0 delay_us :: !samples;
          loop now)
      in
      loop (Unix.gettimeofday ()))
    (fun () ->
      Eio.Time.sleep clock 0.005;
      let started = Mtime_clock.counter () in
      result := Some (f ());
      wall_ms :=
        (Mtime.Span.to_uint64_ns (Mtime_clock.count started)
         |> Int64.to_float
         |> fun ns -> ns /. 1_000_000.0);
      running := false);
  let after_bytes = Gc.allocated_bytes () in
  let after_gc = Gc.quick_stat () in
  let after_completed = (E.Blocking.Pool.stats pool).completed in
  match !result with
  | None -> failwith (label ^ ": missing scan result")
  | Some { count; sum } ->
      Printf.printf
        "%s rows=%d count=%d sum=%d wall_ms=%.3f allocated_bytes=%.0f minor_words=%.0f promoted_words=%.0f major_words=%.0f heartbeat_p99_us=%.3f heartbeat_max_us=%.3f blocking_completed_delta=%d\n%!"
        label rows count sum !wall_ms (after_bytes -. before_bytes)
        (after_gc.minor_words -. before_gc.minor_words)
        (after_gc.promoted_words -. before_gc.promoted_words)
        (after_gc.major_words -. before_gc.major_words)
        (percentile !samples 99.0) (max_float !samples)
        (after_completed - before_completed)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let rt = Eta.Runtime.create ~sw ~clock () in
  let pool =
    E.Blocking.Pool.create ~name:"sqlite-scan"
      {
        max_threads = 4;
        max_queued = rows + 1;
        queue_policy = E.Blocking.Pool.Wait;
        shutdown_policy = E.Blocking.Pool.Drain;
      }
  in
  let db = setup_db () in
  Fun.protect
    ~finally:(fun () ->
      ignore (S.close db);
      run_ok rt (E.Blocking.Pool.shutdown pool))
    (fun () ->
      measure ~clock ~pool ~label:"A_same_domain_released_runtime" (fun () ->
          scan_same_domain db);
      measure ~clock ~pool ~label:"B_per_row_blocking" (fun () ->
          run_ok rt (scan_per_row_blocking pool db));
      measure ~clock ~pool ~label:"B_materialized_one_blocking" (fun () ->
          run_ok rt (scan_materialized_blocking pool db));
      measure ~clock ~pool ~label:"B_batch_1024_blocking" (fun () ->
          run_ok rt (scan_batch_blocking pool db)))
