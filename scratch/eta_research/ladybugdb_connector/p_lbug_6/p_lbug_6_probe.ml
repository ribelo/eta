open Eta

module L = P_lbug_2

let make_pool rt db =
  let acquire : (L.conn, [> `Pool_shutdown | `Pool_shutdown_timeout ]) Effect.t =
    Effect.sync (fun () -> L.connect db)
  in
  let release conn : (unit, [> `Pool_shutdown | `Pool_shutdown_timeout ]) Effect.t =
    Effect.sync (fun () -> L.close_conn conn)
  in
  let health_check conn =
    Effect.sync (fun () -> if L.check_return1 conn then () else failwith "RETURN 1 failed")
  in
  match Runtime.run rt (Pool.create ~name:"ladybug.pool" ~max_size:2 ~acquire ~release ~health_check ()) with
  | Exit.Ok pool -> pool
  | Exit.Error cause ->
      failwith (Format.asprintf "pool create failed: %a"
        (Cause.pp (fun fmt -> function
          | `Pool_shutdown -> Format.pp_print_string fmt "Pool_shutdown"
          | `Pool_shutdown_timeout -> Format.pp_print_string fmt "Pool_shutdown_timeout"))
        cause)

let run_effect_bool rt eff =
  match Runtime.run rt eff with
  | Exit.Ok b -> Printf.printf "%b" b; b
  | Exit.Error _ -> Printf.printf "error"; false

let safe_ordering () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let db = L.open_memory () in
  let pool = make_pool rt db in
  let use_conn =
    Pool.with_resource pool (fun conn -> Effect.sync (fun () -> L.check_return1 conn))
  in
  Printf.printf "safe.use_before_shutdown=";
  let ok = run_effect_bool rt use_conn in
  Printf.printf "\n";
  let shutdown = Runtime.run rt (Pool.shutdown pool) in
  Printf.printf "safe.pool_shutdown=%s\n"
    (match shutdown with Exit.Ok () -> "Ok" | Exit.Error _ -> "Error");
  L.close_db db;
  Printf.printf "safe.db_closed_after_pool=true\n";
  ok && match shutdown with Exit.Ok () -> true | Exit.Error _ -> false

let unsafe_ordering_child () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let db = L.open_memory () in
  let pool = make_pool rt db in
  let use_conn =
    Pool.with_resource pool (fun conn -> Effect.sync (fun () -> L.check_return1 conn))
  in
  Printf.printf "unsafe.use_before_db_close=";
  ignore (run_effect_bool rt use_conn);
  Printf.printf "\n";
  L.close_db db;
  Printf.printf "unsafe.db_closed_while_pool_alive=true\n";
  Printf.printf "unsafe.use_after_db_close=";
  ignore (run_effect_bool rt use_conn);
  Printf.printf "\n";
  let shutdown = Runtime.run rt (Pool.shutdown pool) in
  Printf.printf "unsafe.pool_shutdown_after_db_close=%s\n"
    (match shutdown with Exit.Ok () -> "Ok" | Exit.Error _ -> "Error");
  flush stdout

let run_unsafe_isolated () =
  flush stdout;
  match Unix.fork () with
  | 0 ->
      (try unsafe_ordering_child (); exit 0 with exn ->
        Printf.printf "unsafe.child_exception=%s\n" (Printexc.to_string exn);
        flush stdout;
        exit 2)
  | pid ->
      let _, status = Unix.waitpid [] pid in
      match status with
      | Unix.WEXITED code -> Printf.printf "unsafe.child_exit=%d\n" code; code = 0
      | Unix.WSIGNALED signal ->
          Printf.printf "unsafe.child_signal=%d\n" signal; false
      | Unix.WSTOPPED signal ->
          Printf.printf "unsafe.child_stopped=%d\n" signal; false

let () =
  Printf.printf "=== P-Lbug-6 LadybugDB Eta.Pool Fit Probe ===\n\n";
  let safe_ok = safe_ordering () in
  Printf.printf "safe.assertion=%s\n" (if safe_ok then "pass" else "fail");
  let unsafe_completed = run_unsafe_isolated () in
  Printf.printf "unsafe.completed=%b\n" unsafe_completed;
  Printf.printf "verdict=%s\n" (if safe_ok then "Partial" else "Falsified");
  Printf.printf "\n=== P-Lbug-6 probe completed ===\n"
