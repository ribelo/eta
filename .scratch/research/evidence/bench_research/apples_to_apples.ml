open Effet

let int_sink = ref 0
let unit_sink = ref ()

type sample = {
  wall_ns : float;
  minor_words : float;
  major_words : float;
}

let sample f =
  Gc.compact ();
  let before = Gc.quick_stat () in
  let started = Unix.gettimeofday () in
  f ();
  let ended = Unix.gettimeofday () in
  let after = Gc.quick_stat () in
  {
    wall_ns = (ended -. started) *. 1_000_000_000.;
    minor_words = after.minor_words -. before.minor_words;
    major_words = after.major_words -. before.major_words;
  }

let mean f xs =
  List.fold_left (fun acc x -> acc +. f x) 0. xs /. float_of_int (List.length xs)

let min f xs = List.fold_left (fun acc x -> Float.min acc (f x)) Float.infinity xs

let run ?(samples = 20) name f =
  let xs = List.init samples (fun _ -> sample f) in
  Printf.printf "%-36s wall_mean_ns=%12.0f wall_min_ns=%12.0f minor_words=%12.0f major_words=%12.0f\n%!"
    name
    (mean (fun x -> x.wall_ns) xs)
    (min (fun x -> x.wall_ns) xs)
    (mean (fun x -> x.minor_words) xs)
    (mean (fun x -> x.major_words) xs)

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

let rec effet_bind_chain n acc =
  if n = 0 then acc
  else effet_bind_chain (n - 1) (Effect.bind (fun x -> Effect.pure (x + 1)) acc)

let effet_fail_catch_loop n =
  let rec go i acc =
    if i = 0 then Effect.pure acc
    else
      Effect.catch
        (fun (`Boom : [ `Boom ]) -> go (i - 1) (acc + 1))
        (Effect.fail `Boom)
  in
  go n 0

let run_effet_int rt program =
  match Runtime.run rt program with
  | Exit.Ok v -> int_sink := Sys.opaque_identity v
  | Exit.Error _ -> failwith "unexpected Effet failure"

let () =
  let bind_n = 100_000 in
  let fail_n = 100_000 in

  Printf.printf "samples=20 bind_n=%d fail_n=%d\n%!" bind_n fail_n;

  run "direct.loop.100k" (fun () -> direct_loop bind_n);
  run "direct.closure_bind.100k" (fun () -> direct_closure_bind bind_n);

  let mini_bind = mini_bind_chain bind_n (Pure 0) in
  let mini_fail = mini_fail_catch_loop fail_n in
  run "mini.bind.100k.prebuilt" (fun () -> run_mini_int mini_bind);
  run "mini.bind.100k.build_run" (fun () ->
      run_mini_int (mini_bind_chain bind_n (Pure 0)));
  run "mini.fail_catch.100k.prebuilt" (fun () -> run_mini_int mini_fail);
  run "mini.fail_catch.100k.build_run" (fun () ->
      run_mini_int (mini_fail_catch_loop fail_n));

  run "eio.setup" (fun () ->
      Eio_main.run @@ fun _stdenv ->
      Eio.Switch.run @@ fun _sw -> unit_sink := ());

  run "effet.setup_pure" (fun () ->
      Eio_main.run @@ fun stdenv ->
      Eio.Switch.run @@ fun sw ->
      let rt =
        Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
      in
      run_effet_int rt (Effect.pure 0));

  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  let effet_bind = effet_bind_chain bind_n (Effect.pure 0) in
  let effet_fail = effet_fail_catch_loop fail_n in
  run "effet.pure.reused_rt" (fun () -> run_effet_int rt (Effect.pure 0));
  run "effet.bind.100k.prebuilt" (fun () -> run_effet_int rt effet_bind);
  run "effet.bind.100k.build_run" (fun () ->
      run_effet_int rt (effet_bind_chain bind_n (Effect.pure 0)));
  run "effet.fail_catch.100k.prebuilt" (fun () -> run_effet_int rt effet_fail);
  run "effet.fail_catch.100k.build_run" (fun () ->
      run_effet_int rt (effet_fail_catch_loop fail_n))
