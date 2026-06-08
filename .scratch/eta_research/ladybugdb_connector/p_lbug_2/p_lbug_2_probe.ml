open Eta

module L = P_lbug_2

let setup conn =
  L.exec conn "CREATE NODE TABLE N(id INT64, PRIMARY KEY(id))";
  L.exec conn "UNWIND range(1, 20000) AS i CREATE (:N {id: i})"

let long_query = "MATCH (a:N), (b:N), (c:N) RETURN sum(a.id + b.id + c.id)"

let () =
  Printf.printf "=== P-Lbug-2 LadybugDB Cancellation Probe ===\n";
  Printf.printf "hypothesis=Effect.timeout plus lbug_connection_interrupt leaves connection reusable\n";
  flush stdout;

  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
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

      let cancel_count = Atomic.make 0 in
      let start_us = L.monotonic_us () in
      let eff =
        Effect.blocking ~name:"ladybug.long_query"
          ~on_cancel:(fun () ->
            Atomic.incr cancel_count;
            L.interrupt conn)
          (fun () -> L.query conn long_query)
        |> Effect.timeout (Duration.ms 200)
      in
      let result = Runtime.run rt eff in
      let end_us = L.monotonic_us () in
      let elapsed_ms = (end_us -. start_us) /. 1000.0 in
      let reusable = L.check_return1 conn in

      Printf.printf "timeout_ms=200\n";
      Printf.printf "elapsed_ms=%.3f\n" elapsed_ms;
      Printf.printf "on_cancel_calls=%d\n" (Atomic.get cancel_count);
      (match result with
      | Exit.Ok value -> Printf.printf "effect_result=Ok:%s\n" value
      | Exit.Error (Cause.Fail `Timeout) ->
          Printf.printf "effect_result=Error:Timeout\n"
      | Exit.Error cause ->
          let rendered =
            Format.asprintf "%a"
              (Cause.pp (fun fmt (`Timeout : [ `Timeout ]) ->
                   Format.pp_print_string fmt "Timeout"))
              cause
          in
          Printf.printf "effect_result=Error:%s\n" rendered);
      Printf.printf "connection_reusable=%b\n" reusable;
      Printf.printf "verdict=%s\n"
        (match result with
        | Exit.Error (Cause.Fail `Timeout) when reusable -> "Confirmed"
        | Exit.Error (Cause.Fail `Timeout) -> "Falsified_connection_not_reusable"
        | Exit.Ok _ -> "Partial_query_completed_before_timeout"
        | Exit.Error _ -> "Partial_unexpected_error");
      flush stdout)
