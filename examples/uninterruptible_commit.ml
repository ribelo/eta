open Eta

let critical_commit committed =
  Effect.delay (Duration.ms 20)
    (Effect.sync (fun () ->
         committed := true;
         "committed"))
  |> Effect.uninterruptible

let program committed =
  Effect.race [ critical_commit committed; Effect.pure "fast" ]

let pp_never fmt = function _ -> Format.pp_print_string fmt "<never>"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let committed = ref false in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program committed) with
  | Exit.Ok winner ->
      if not !committed then failwith "uninterruptible commit did not finish";
      Format.printf "uninterruptible-commit:winner=%s committed=%b@." winner
        !committed
  | Exit.Error cause ->
      Format.eprintf "uninterruptible commit failed: %a@." (Cause.pp pp_never)
        cause;
      exit 1
