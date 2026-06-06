open Eta

let run_effect program =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  ignore (Runtime.run rt program : (_, _) Exit.t)

let rec bind_chain n acc =
  if n = 0 then acc
  else bind_chain (n - 1) (Effect.bind (fun x -> Effect.pure (x + 1)) acc)

let bind_left n =
  let rec go i =
    if i = 0 then Effect.pure 0
    else Effect.bind (fun x -> Effect.pure (x + 1)) (go (i - 1))
  in
  go n

let rec map_chain n acc =
  if n = 0 then acc else map_chain (n - 1) (Effect.map (( + ) 1) acc)

let sync_chain n =
  let rec go i =
    if i = 0 then Effect.pure 0
    else
      Effect.bind
        (fun _ -> go (i - 1))
        (Effect.sync (fun () -> i))
  in
  go n

let workloads =
  let core name run =
    { Bench_lib.name = "effect.core." ^ name; run; samples = None }
  in
  [
    core "pure_run" (fun () -> run_effect (Effect.pure 0));
    core "bind_right.1k" (fun () -> run_effect (bind_chain 1_000 (Effect.pure 0)));
    core "bind_right.10k" (fun () -> run_effect (bind_chain 10_000 (Effect.pure 0)));
    core "bind_right.100k" (fun () -> run_effect (bind_chain 100_000 (Effect.pure 0)));
    core "bind_left.1k" (fun () -> run_effect (bind_left 1_000));
    core "bind_left.10k" (fun () -> run_effect (bind_left 10_000));
    core "bind_left.100k" (fun () -> run_effect (bind_left 100_000));
    core "map_chain.1k" (fun () -> run_effect (map_chain 1_000 (Effect.pure 0)));
    core "map_chain.10k" (fun () -> run_effect (map_chain 10_000 (Effect.pure 0)));
    core "map_chain.100k" (fun () -> run_effect (map_chain 100_000 (Effect.pure 0)));
    core "sync.1" (fun () -> run_effect (sync_chain 1));
    core "sync.100" (fun () -> run_effect (sync_chain 100));
    core "sync.10000" (fun () -> run_effect (sync_chain 10_000));
    core "catch_success" (fun () ->
        run_effect
          (Effect.catch (fun (`Boom : [ `Boom ]) -> Effect.pure 0) (Effect.pure 1)));
    core "catch_failure" (fun () ->
        run_effect
          (Effect.catch (fun (`Boom : [ `Boom ]) -> Effect.pure 1) (Effect.fail `Boom)));
    core "tap_error_failure" (fun () ->
        run_effect
          (Effect.tap_error (fun (`Boom : [ `Boom ]) -> ()) (Effect.fail `Boom)));
    core "fail_then_catch" (fun () ->
        run_effect
          (Effect.fail `Boom
          |> Effect.catch (fun (`Boom : [ `Boom ]) -> Effect.pure 1)));
    core "runtime_create_run_shutdown" (fun () -> run_effect (Effect.pure 0));
  ]

let () = Bench_lib.run (Bench_lib.parse_args ()) workloads
