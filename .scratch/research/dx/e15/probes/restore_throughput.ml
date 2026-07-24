open Eta

let batch iterations =
  let one = Effect.uninterruptible (Effect.interruptible Effect.unit) in
  let rec loop remaining =
    if remaining = 0 then Effect.unit
    else Effect.bind (fun () -> loop (remaining - 1)) one
  in
  loop iterations

let expect_ok = function
  | Exit.Ok () -> ()
  | Exit.Error cause ->
    failwith
      (Format.asprintf "restore throughput failed: %a"
         (Cause.pp (fun fmt _ -> Format.pp_print_string fmt "<error>"))
         cause)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let runtime = Eta_eio.Runtime.create ~sw ~clock () in
  expect_ok (Eta_eio.Runtime.run runtime (batch 10_000));
  let iterations = 100_000 in
  let started = Eio.Time.now clock in
  expect_ok (Eta_eio.Runtime.run runtime (batch iterations));
  let elapsed_s = Eio.Time.now clock -. started in
  let restorations_per_s = float iterations /. elapsed_s in
  Printf.printf
    "restore-throughput: iterations=%d elapsed_s=%.6f restorations_per_s=%.0f\n"
    iterations elapsed_s restorations_per_s
