open Eta

module L = P_lbug_2

let heartbeat_fibers = 16
let heartbeat_interval = 0.001
let sample_seconds = 5.0

let setup conn =
  L.exec conn "CREATE NODE TABLE N(id INT64, PRIMARY KEY(id))";
  L.exec conn "UNWIND range(1, 20000) AS i CREATE (:N {id: i})"

let long_query = "MATCH (a:N), (b:N), (c:N) RETURN sum(a.id + b.id + c.id)"

let percentile pct values =
  let arr = Array.of_list values in
  Array.sort Float.compare arr;
  if Array.length arr = 0 then 0.0
  else
    let idx =
      int_of_float (ceil (pct *. float_of_int (Array.length arr)) -. 1.0)
      |> max 0 |> min (Array.length arr - 1)
    in
    arr.(idx)

let () =
  Printf.printf "=== P-Lbug-5 LadybugDB Effect.blocking Fairness Probe ===\n";
  Printf.printf "heartbeat_fibers=%d\n" heartbeat_fibers;
  Printf.printf "heartbeat_interval_ms=1\n";
  Printf.printf "sample_seconds=%.0f\n" sample_seconds;
  flush stdout;

  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock stdenv in
  let rt = Runtime.create ~sw ~clock () in
  let db = L.open_memory () in
  let conn = L.connect db in
  Fun.protect
    ~finally:(fun () ->
      L.close_conn conn;
      L.close_db db)
    (fun () ->
      Printf.printf "setup=begin\n";
      flush stdout;
      setup conn;
      Printf.printf "setup=done\n";
      flush stdout;

      let query_started = Atomic.make false in
      let query_finished = Atomic.make false in
      let query_result = Atomic.make "not-started" in
      Eio.Fiber.fork ~sw (fun () ->
        Atomic.set query_started true;
        let eff =
          Effect.blocking ~name:"ladybug.fairness.long_query"
            ~on_cancel:(fun () -> L.interrupt conn)
            (fun () -> L.query conn long_query)
          |> Effect.timeout (Duration.seconds 5)
        in
        let result = Runtime.run rt eff in
        let rendered =
          match result with
          | Exit.Ok value -> "Ok:" ^ value
          | Exit.Error (Cause.Fail `Timeout) -> "Error:Timeout"
          | Exit.Error cause ->
              Format.asprintf "Error:%a"
                (Cause.pp (fun fmt (`Timeout : [ `Timeout ]) ->
                     Format.pp_print_string fmt "Timeout"))
                cause
        in
        Atomic.set query_result rendered;
        Atomic.set query_finished true);

      while not (Atomic.get query_started) do
        Eio.Fiber.yield ()
      done;

      let samples = ref [] in
      let active = Atomic.make heartbeat_fibers in
      for _ = 1 to heartbeat_fibers do
        Eio.Fiber.fork ~sw (fun () ->
          let deadline = Eio.Time.now clock +. sample_seconds in
          let expected = ref (Eio.Time.now clock +. heartbeat_interval) in
          while Eio.Time.now clock < deadline do
            Eio.Time.sleep_until clock !expected;
            let now = Eio.Time.now clock in
            let jitter_ms = max 0.0 ((now -. !expected) *. 1000.0) in
            samples := jitter_ms :: !samples;
            expected := !expected +. heartbeat_interval
          done;
          Atomic.decr active)
      done;

      while Atomic.get active > 0 do
        Eio.Time.sleep clock 0.01
      done;
      let values = !samples in
      let p50 = percentile 0.50 values in
      let p99 = percentile 0.99 values in
      let max_jitter = percentile 1.0 values in
      if not (Atomic.get query_finished) then L.interrupt conn;
      let wait_deadline = Eio.Time.now clock +. 2.0 in
      while (not (Atomic.get query_finished)) && Eio.Time.now clock < wait_deadline do
        Eio.Time.sleep clock 0.001
      done;
      let reusable =
        if Atomic.get query_finished then L.check_return1 conn else false
      in
      Printf.printf "samples=%d\n" (List.length values);
      Printf.printf "jitter_p50_ms=%.3f\n" p50;
      Printf.printf "jitter_p99_ms=%.3f\n" p99;
      Printf.printf "jitter_max_ms=%.3f\n" max_jitter;
      Printf.printf "query_result=%s\n" (Atomic.get query_result);
      Printf.printf "query_finished=%b\n" (Atomic.get query_finished);
      Printf.printf "connection_reusable=%b\n" reusable;
      Printf.printf "verdict=%s\n"
        (if p99 < 10.0 && reusable then "Partial_5s_window" else "Partial_or_Falsified");
      flush stdout)
