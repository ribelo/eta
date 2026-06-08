open Effet

let run_effect program =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt =
    Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) ~env:() ()
  in
  ignore (Runtime.run rt program : (_, _) Exit.t)

let bind_chain n =
  let rec go i acc =
    if i = 0 then acc
    else go (i - 1) (Effect.bind (fun x -> Effect.pure (x + 1)) acc)
  in
  go n (Effect.pure 0)

let () =
  Bench_lib.run (Bench_lib.parse_args ())
    [
      { Bench_lib.name = "research.custom.bind.1k"; run = (fun () -> run_effect (bind_chain 1_000)); samples = Some 3 };
      { Bench_lib.name = "research.custom.bind.10k"; run = (fun () -> run_effect (bind_chain 10_000)); samples = Some 3 };
    ]
