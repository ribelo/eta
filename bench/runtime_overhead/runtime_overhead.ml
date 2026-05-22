open Eta

let int_sink = ref 0
let unit_sink = ref ()
let one = Sys.opaque_identity 1

let direct_loop n =
  let rec go i acc =
    if i = 0 then acc else go (i - 1) (Sys.opaque_identity (acc + one))
  in
  int_sink := Sys.opaque_identity (go n 0)

let direct_closure_bind n =
  let bind x f = f x in
  let pure x = x in
  let rec go i acc =
    if i = 0 then acc
    else go (i - 1) (bind acc (fun x -> pure (Sys.opaque_identity (x + one))))
  in
  int_sink := Sys.opaque_identity (go n 0)

type ('err, 'a) mini =
  | Pure : 'a -> ('err, 'a) mini
  | Fail : 'err -> ('err, 'a) mini
  | Bind : ('err, 'b) mini * ('b -> ('err, 'a) mini) -> ('err, 'a) mini
  | Catch : ('err, 'a) mini * ('err -> ('err, 'a) mini) -> ('err, 'a) mini

let rec run_mini : type err a. (err, a) mini -> (a, err) result = function
  | Pure x -> Ok x
  | Fail err -> Error err
  | Bind (left, k) -> (
      match run_mini left with
      | Ok x -> run_mini (k x)
      | Error err -> Error err)
  | Catch (body, handler) -> (
      match run_mini body with
      | Ok x -> Ok x
      | Error err -> run_mini (handler err))

let rec mini_bind_chain n acc =
  if n = 0 then acc
  else mini_bind_chain (n - 1) (Bind (acc, fun x -> Pure (x + 1)))

let mini_fail_catch_loop n =
  let rec go i acc =
    if i = 0 then Pure acc
    else Catch (Fail `Boom, fun `Boom -> go (i - 1) (acc + 1))
  in
  go n 0

let run_mini_int program =
  match run_mini program with
  | Ok v -> int_sink := Sys.opaque_identity v
  | Error _ -> failwith "unexpected mini failure"

let rec eta_bind_chain n acc =
  if n = 0 then acc
  else eta_bind_chain (n - 1) (Effect.bind (fun x -> Effect.pure (x + 1)) acc)

let eta_fail_catch_loop n =
  let rec go i acc =
    if i = 0 then Effect.pure acc
    else
      Effect.catch
        (fun (`Boom : [ `Boom ]) -> go (i - 1) (acc + 1))
        (Effect.fail `Boom)
  in
  go n 0

let run_eta_int rt program =
  match Runtime.run rt program with
  | Exit.Ok v -> int_sink := Sys.opaque_identity v
  | Exit.Error _ -> failwith "unexpected Eta failure"

let workload name run = { Bench_lib.name = "overhead." ^ name; run; samples = None }

let bind_n = 100_000
let fail_n = 100_000

let direct_and_mini_workloads () =
  let mini_bind = mini_bind_chain bind_n (Pure 0) in
  let mini_fail = mini_fail_catch_loop fail_n in
  [
    workload "direct.loop.100k" (fun () -> direct_loop bind_n);
    workload "direct.closure_bind.100k" (fun () -> direct_closure_bind bind_n);
    workload "mini.bind.100k.prebuilt" (fun () -> run_mini_int mini_bind);
    workload "mini.bind.100k.build_run" (fun () ->
        run_mini_int (mini_bind_chain bind_n (Pure 0)));
    workload "mini.fail_catch.100k.prebuilt" (fun () -> run_mini_int mini_fail);
    workload "mini.fail_catch.100k.build_run" (fun () ->
        run_mini_int (mini_fail_catch_loop fail_n));
  ]

let setup_workloads () =
  [
    workload "eio.setup" (fun () ->
        Eio_main.run @@ fun _stdenv ->
        Eio.Switch.run @@ fun _sw -> unit_sink := ());
    workload "eta.setup_pure" (fun () ->
        Eio_main.run @@ fun stdenv ->
        Eio.Switch.run @@ fun sw ->
        let rt =
          Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
        in
        run_eta_int rt (Effect.pure 0));
  ]

let eta_workloads rt =
  let eta_bind = eta_bind_chain bind_n (Effect.pure 0) in
  let eta_fail = eta_fail_catch_loop fail_n in
  [
    workload "eta.pure.reused_rt" (fun () -> run_eta_int rt (Effect.pure 0));
    workload "eta.bind.100k.prebuilt" (fun () -> run_eta_int rt eta_bind);
    workload "eta.bind.100k.build_run" (fun () ->
        run_eta_int rt (eta_bind_chain bind_n (Effect.pure 0)));
    workload "eta.fail_catch.100k.prebuilt" (fun () -> run_eta_int rt eta_fail);
    workload "eta.fail_catch.100k.build_run" (fun () ->
        run_eta_int rt (eta_fail_catch_loop fail_n));
  ]

let () =
  let opts = Bench_lib.parse_args () in
  Bench_lib.run opts (direct_and_mini_workloads ());
  Bench_lib.run opts (setup_workloads ());
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ()
  in
  Bench_lib.run opts (eta_workloads rt)

