open Eta

let log fmt = Printf.ksprintf (fun s -> print_endline s; flush stdout) fmt

let run_effect eff =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  Runtime.run rt eff

let expect_ok label = function
  | Exit.Ok value ->
      log "%s=Ok" label;
      value
  | Exit.Error _ ->
      log "%s=Error" label;
      exit 1

let make_pool db =
  let acquire = Effect.sync (fun () -> db) in
  let release _conn = Effect.unit in
  let health_check conn =
    Effect.sync (fun () ->
        if Pt_pool.exec_sql conn "SELECT 1" then () else failwith "health")
  in
  Pool.create ~name:"pt.turso.pool" ~kind:"turso" ~max_size:2 ~acquire
    ~release ~health_check ()

let use_pool pool =
  Pool.with_resource pool (fun conn ->
      Effect.sync (fun () -> Pt_pool.exec_sql conn "SELECT 1"))

let safe_case path =
  log "safe.path=%s" path;
  let db = Pt_pool.open_file path in
  let pool = expect_ok "safe.create" (run_effect (make_pool db)) in
  let ok = expect_ok "safe.use" (run_effect (use_pool pool)) in
  log "safe.use.ok=%b" ok;
  expect_ok "safe.shutdown" (run_effect (Pool.shutdown ~deadline:(Duration.ms 100) pool));
  Pt_pool.close_db db;
  log "safe.close_db_after_pool=Ok"

let unsafe_child path =
  let db = Pt_pool.open_file path in
  let pool = expect_ok "unsafe.create" (run_effect (make_pool db)) in
  let ok = expect_ok "unsafe.use_before_close" (run_effect (use_pool pool)) in
  log "unsafe.use_before_close.ok=%b" ok;
  Pt_pool.close_db db;
  log "unsafe.close_db_while_pool_live=Ok";
  let after = run_effect (use_pool pool) in
  (match after with
  | Exit.Ok ok -> log "unsafe.use_after_close=Ok %b" ok
  | Exit.Error _ -> log "unsafe.use_after_close=Error");
  let shutdown = run_effect (Pool.shutdown ~deadline:(Duration.ms 100) pool) in
  (match shutdown with
  | Exit.Ok () -> log "unsafe.shutdown_after_close=Ok"
  | Exit.Error _ -> log "unsafe.shutdown_after_close=Error")

let unsafe_case path =
  match Unix.fork () with
  | 0 ->
      ignore (Unix.alarm 5);
      unsafe_child path;
      exit 0
  | pid ->
      let rec wait attempts =
        match Unix.waitpid [ Unix.WNOHANG ] pid with
        | 0, _ when attempts <= 0 ->
            Unix.kill pid Sys.sigkill;
            let _, status = Unix.waitpid [] pid in
            status
        | 0, _ ->
            Unix.sleepf 0.1;
            wait (attempts - 1)
        | _, status -> status
      in
      let status = wait 50 in
      (match status with
      | Unix.WEXITED code -> log "unsafe.child=WEXITED %d" code
      | Unix.WSIGNALED signal -> log "unsafe.child=WSIGNALED %d" signal
      | Unix.WSTOPPED signal -> log "unsafe.child=WSTOPPED %d" signal)

let () =
  let base =
    Filename.concat (Filename.get_temp_dir_name ())
      ("eta_turso_pool_" ^ string_of_int (Unix.getpid ()))
  in
  let safe_path = base ^ "_safe.db" in
  let unsafe_path = base ^ "_unsafe.db" in
  List.iter
    (fun path -> try Sys.remove path with Sys_error _ -> ())
    [ safe_path; unsafe_path ];
  log "=== P-Turso-4 file-backed Eta.Pool fit ===";
  safe_case safe_path;
  unsafe_case unsafe_path;
  log "verdict=Partial";
  log "note=Safe pool shutdown before database close works; unsafe close is isolated in child and must not be supported.";
  List.iter
    (fun path -> try Sys.remove path with Sys_error _ -> ())
    [ safe_path; unsafe_path ]
