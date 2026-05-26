module Q = Sql
module S = Sqlite
module E = Eta.Effect

let rows = 50_000
let scan_fibers = 8
let query_fibers = 8
let query_iterations = 1_000
let batch_size = 1_024
let heartbeat_interval = 0.001

type event =
  | Scan_done of {
      id : int;
      rows : int;
      sum : int;
      wall_us : float;
    }
  | Query_done of {
      id : int;
      samples_us : float list;
    }

let run_ok rt eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error cause ->
      failwith
        (Format.asprintf "Eta failure: %a"
           (Eta.Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<err>"))
           cause)

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

let setup_db path =
  if Sys.file_exists path then Sys.remove path;
  let config =
    {
      (S.default_config path) with
      busy_timeout_ms = Some 250;
      journal_mode = Some `Wal;
      synchronous = Some `Normal;
    }
  in
  let db = S.open_with_config config in
  Fun.protect
    ~finally:(fun () -> ignore (S.close db))
    (fun () ->
      S.exec_script db
        (Printf.sprintf
           "PRAGMA temp_store = MEMORY;\n\
            CREATE TABLE items (id INTEGER PRIMARY KEY, value INTEGER NOT NULL);\n\
            WITH RECURSIVE cnt(x) AS (\n\
              SELECT 1 UNION ALL SELECT x + 1 FROM cnt WHERE x < %d\n\
            ) INSERT INTO items (id, value) SELECT x, x FROM cnt"
           rows));
  config

let scan_job ~blocking_pool ~timeout pool id =
  E.sync Unix.gettimeofday
  |> E.bind (fun started ->
         Q.Eta_pool.fold ~blocking_pool ~timeout ~batch_size pool
           "SELECT value FROM items ORDER BY id" [] ~init:(0, 0)
           ~f:(fun (count, sum) row ->
             match Q.Row.int "value" row with
             | Some value -> (count + 1, sum + value)
             | None -> failwith "missing value")
         |> E.bind (fun (count, sum) ->
                E.sync (fun () ->
                    Scan_done
                      {
                        id;
                        rows = count;
                        sum;
                        wall_us = (Unix.gettimeofday () -. started) *. 1_000_000.0;
                      })))

let query_job ~blocking_pool ~timeout pool id =
  let rec loop remaining samples =
    if remaining = 0 then
      E.pure (Query_done { id; samples_us = samples })
    else
      let key = ((id * 997) + remaining) mod rows + 1 in
      E.sync Unix.gettimeofday
      |> E.bind (fun started ->
             Q.Eta_pool.query ~blocking_pool ~timeout pool
               "SELECT value FROM items WHERE id = ?" [ Q.Value.int key ]
             |> E.bind (function
                  | [ row ] when Q.Row.int "value" row = Some key ->
                      let elapsed =
                        (Unix.gettimeofday () -. started) *. 1_000_000.0
                      in
                      loop (remaining - 1) (elapsed :: samples)
                  | _ -> E.sync (fun () -> failwith "unexpected query row")))
  in
  loop query_iterations []

let event_samples = function
  | Query_done { samples_us; _ } -> samples_us
  | Scan_done _ -> []

let scan_walls = function
  | Scan_done { wall_us; _ } -> [ wall_us ]
  | Query_done _ -> []

let validate_event = function
  | Query_done _ -> ()
  | Scan_done { rows = count; sum; id = _; wall_us = _ } ->
      let expected_sum = rows * (rows + 1) / 2 in
      if count <> rows || sum <> expected_sum then
        failwith
          (Printf.sprintf "bad scan result count=%d sum=%d expected_sum=%d" count
             sum expected_sum)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let rt = Eta.Runtime.create ~sw ~clock () in
  let blocking_pool =
    E.Blocking.Pool.create ~name:"sqlite-fanout"
      {
        max_threads = 4;
        max_queued = 256;
        queue_policy = E.Blocking.Pool.Wait;
        shutdown_policy = E.Blocking.Pool.Drain;
      }
  in
  let path = Filename.temp_file "eta-sqlite-fanout-" ".db" in
  let config = setup_db path in
  Fun.protect
    ~finally:(fun () ->
      run_ok rt (E.Blocking.Pool.shutdown blocking_pool);
      if Sys.file_exists path then Sys.remove path;
      let wal = path ^ "-wal" in
      let shm = path ^ "-shm" in
      if Sys.file_exists wal then Sys.remove wal;
      if Sys.file_exists shm then Sys.remove shm)
    (fun () ->
      let timeout = Eta.Duration.ms 5_000 in
      let program =
        Q.Eta_pool.create ~blocking_pool ~max_size:(scan_fibers + query_fibers) config
        |> E.bind (fun pool ->
               let jobs =
                 List.init scan_fibers (fun id ->
                     scan_job ~blocking_pool ~timeout pool id)
                 @ List.init query_fibers (fun id ->
                       query_job ~blocking_pool ~timeout pool id)
               in
               E.all jobs
               |> E.bind (fun events ->
                      Q.Eta_pool.shutdown pool |> E.map (fun () -> events)))
      in
      let samples = ref [] in
      let max_active = ref 0 in
      let max_queued = ref 0 in
      let running = ref true in
      let events = ref [] in
      let wall_started = Unix.gettimeofday () in
      Eio.Fiber.both
        (fun () ->
          let rec loop last =
            if !running then (
              Eio.Time.sleep clock heartbeat_interval;
              let now = Unix.gettimeofday () in
              let delay_us =
                ((now -. last) -. heartbeat_interval) *. 1_000_000.0
              in
              samples := max 0.0 delay_us :: !samples;
              let stats = E.Blocking.Pool.stats blocking_pool in
              max_active := max !max_active stats.active;
              max_queued := max !max_queued stats.queued;
              loop now)
          in
          loop (Unix.gettimeofday ()))
        (fun () ->
          Eio.Time.sleep clock 0.005;
          events := run_ok rt program;
          running := false);
      let wall_ms = (Unix.gettimeofday () -. wall_started) *. 1_000.0 in
      List.iter validate_event !events;
      let query_samples = List.concat_map event_samples !events in
      let scan_samples = List.concat_map scan_walls !events in
      let stats = E.Blocking.Pool.stats blocking_pool in
      Printf.printf "fanout_scan_fibers=%d\n" scan_fibers;
      Printf.printf "fanout_query_fibers=%d\n" query_fibers;
      Printf.printf "fanout_query_iterations=%d\n" query_iterations;
      Printf.printf "fanout_blocking_max_threads=4\n";
      Printf.printf "fanout_wall_ms=%.3f\n" wall_ms;
      Printf.printf "query_latency_p50_us=%.3f\n" (percentile query_samples 50.0);
      Printf.printf "query_latency_p95_us=%.3f\n" (percentile query_samples 95.0);
      Printf.printf "query_latency_p99_us=%.3f\n" (percentile query_samples 99.0);
      Printf.printf "query_latency_max_us=%.3f\n" (max_float query_samples);
      Printf.printf "scan_wall_p50_us=%.3f\n" (percentile scan_samples 50.0);
      Printf.printf "scan_wall_max_us=%.3f\n" (max_float scan_samples);
      Printf.printf "heartbeat_p99_us=%.3f\n" (percentile !samples 99.0);
      Printf.printf "heartbeat_max_us=%.3f\n" (max_float !samples);
      Printf.printf "blocking_max_active=%d\n" !max_active;
      Printf.printf "blocking_max_queued=%d\n" !max_queued;
      Printf.printf "blocking_completed=%d\n" stats.completed)
