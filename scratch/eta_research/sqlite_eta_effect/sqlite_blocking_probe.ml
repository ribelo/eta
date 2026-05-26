module S = Sqlite
module E = Eta.Effect

let now_us () = int_of_float (Unix.gettimeofday () *. 1_000_000.0)

let percentile sorted pct =
  match sorted with
  | [] -> 0
  | _ ->
      let len = List.length sorted in
      let idx =
        float_of_int (len - 1) *. pct |> int_of_float |> min (len - 1) |> max 0
      in
      List.nth sorted idx

let heartbeat_p99_us body =
  let running = ref true in
  let samples = ref [] in
  Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork ~sw (fun () ->
      let target = ref (now_us () + 1_000) in
      while !running do
        Eio_unix.sleep 0.001;
        let actual = now_us () in
        samples := max 0 (actual - !target) :: !samples;
        target := actual + 1_000
      done);
  Eio.Fiber.yield ();
  let result = body () in
  running := false;
  Eio.Fiber.yield ();
  let sorted = List.sort compare !samples in
  (percentile sorted 0.99, result)

let temp_db () =
  let path = Filename.temp_file "eta-sqlite-effect-" ".db" in
  Sys.remove path;
  path

let locked_pair () =
  let path = temp_db () in
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

let close_locked (path, owner, contender) =
  ignore (S.rollback_result owner);
  ignore (S.close contender);
  ignore (S.close owner);
  if Sys.file_exists path then Sys.remove path

let locked_insert contender =
  S.exec_result contender "INSERT INTO items (id) VALUES (1)"

let run_ok rt eff =
  match Eta.Runtime.run rt eff with
  | Eta.Exit.Ok value -> value
  | Eta.Exit.Error _ -> failwith "unexpected Eta failure"

let effect_blocking_insert ~pool contender =
  E.blocking ~pool ~name:"sqlite.locked_insert" (fun () ->
      locked_insert contender)

let busy_result = function
  | Error err -> not (S.rc_equal err.S.code S.misuse)
  | Ok _ -> false

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let direct_fixture = locked_pair () in
  let direct_p99, direct_result =
    Fun.protect
      ~finally:(fun () -> close_locked direct_fixture)
      (fun () ->
        heartbeat_p99_us (fun () ->
            let _, _, contender = direct_fixture in
            locked_insert contender))
  in
  let blocking_fixture = locked_pair () in
  let pool =
    E.Blocking.Pool.create ~name:"sqlite-research"
      {
        max_threads = 1;
        max_queued = 4;
        queue_policy = E.Blocking.Pool.Wait;
        shutdown_policy = E.Blocking.Pool.Drain;
      }
  in
  let rt = Eta.Runtime.create ~sw ~clock:(Eio.Stdenv.clock env) () in
  let blocking_p99, blocking_result =
    Fun.protect
      ~finally:(fun () -> close_locked blocking_fixture)
      (fun () ->
        heartbeat_p99_us (fun () ->
            let _, _, contender = blocking_fixture in
            run_ok rt (effect_blocking_insert ~pool contender)))
  in
  let stats = E.Blocking.Pool.stats pool in
  run_ok rt (E.Blocking.Pool.shutdown pool);
  Printf.printf "direct_p99_us=%d\n" direct_p99;
  Printf.printf "blocking_p99_us=%d\n" blocking_p99;
  Printf.printf "blocking_completed=%d\n" stats.completed;
  Printf.printf "direct_busy=%b\n" (busy_result direct_result);
  Printf.printf "blocking_busy=%b\n" (busy_result blocking_result)

