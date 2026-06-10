open Eta
open Test_eta_support

(* Runtime.drain should wait for daemon fibers without burning a CPU core. This
   is an Eio host/runtime timing probe because it measures Unix wall time and
   scheduler CPU time. *)
let test_drain_does_not_busy_wait () =
  run_eio @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  let daemon_body = Effect.sync (fun () -> Eio_unix.sleep 0.1) in
  (match Runtime.run rt (Effect.daemon daemon_body) with
  | Exit.Ok () -> ()
  | Exit.Error _ -> Alcotest.fail "daemon launch failed");
  let cpu_before = Sys.time () in
  let wall_before = Unix.gettimeofday () in
  Runtime.drain rt;
  let cpu_after = Sys.time () in
  let wall_after = Unix.gettimeofday () in
  let cpu_ms = (cpu_after -. cpu_before) *. 1000.0 in
  let wall_ms = (wall_after -. wall_before) *. 1000.0 in
  Alcotest.(check bool)
    (Printf.sprintf
       "drain should not busy-wait (CPU: %.1fms during %.1fms wall)"
       cpu_ms wall_ms)
    true (cpu_ms < 10.0)
