open Eta

type user = {
  id : string;
  name : string;
}

let load_user =
  Effect.pure { id = "42"; name = "Ada" }

let program seen =
  load_user
  |> Effect.tap_sync (fun user -> seen := ("loaded:" ^ user.id) :: !seen)
  |> Effect.tap (fun user ->
         Effect.event ~attrs:[ ("user.id", user.id) ] "user.loaded")
  |> Effect.map (fun user -> user.name)

let pp_never fmt = function _ -> Format.pp_print_string fmt "<never>"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let seen = ref [] in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program seen) with
  | Exit.Ok name ->
      Format.printf "tap-success:user=%s audit=%s@." name
        (String.concat "," (List.rev !seen))
  | Exit.Error cause ->
      Format.eprintf "tap success failed: %a@." (Cause.pp pp_never) cause;
      exit 1
