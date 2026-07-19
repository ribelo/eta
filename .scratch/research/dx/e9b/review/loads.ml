(* Review packet — concurrent user/perms loads with Effect.par. *)

open Eta

let load name =
  Effect.sync (fun () -> "loaded:" ^ name)

let loads () =
  Effect.par (load "user") (load "perms")

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (loads ()) with
  | Exit.Ok (user, perms) ->
      Format.printf "user=%s perms=%s@." user perms
  | Exit.Error cause ->
      Format.eprintf "loads failed: %a@."
        (Cause.pp Format.pp_print_string) cause;
      exit 1
