open Eta

let pp_error fmt = function
  | `Too_small -> Format.pp_print_string fmt "too-small"

let program () =
  let open Syntax in
  (let* n =
     Effect.sync_result (fun () -> Ok (1 + 1))
   in
   if n < 3 then Effect.fail `Too_small else Effect.pure n)
  |> Effect.fold ~ok:Fun.id ~error:(function `Too_small -> 3)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program ()) with
  | Exit.Ok n -> Format.printf "quickstart:%d@." n
  | Exit.Error cause ->
      Format.eprintf "quickstart failed: %a@." (Cause.pp pp_error) cause;
      exit 1
