open Eta

type error = [ `Unexpected ] [@@deriving eta_error]

let critical_commit committed =
  Effect.delay (Duration.ms 20)
    (Effect.sync (fun () ->
         committed := true;
         "committed"))
  |> Effect.uninterruptible

let program committed =
  Effect.race [ critical_commit committed; Effect.pure "fast" ]

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
      Format.eprintf "uninterruptible commit failed: %a@." (Cause.pp pp_error)
        cause;
      exit 1
