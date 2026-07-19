open Eta

type user = {
  id : string;
  name : string;
}

type error = [ `Unexpected ] [@@deriving eta_error]

let load_user =
  Effect.pure { id = "42"; name = "Ada" }

let label =
  let open Syntax in
  let+ user = load_user in
  "user:" ^ user.id ^ ":" ^ user.name

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt label with
  | Exit.Ok value -> Format.printf "map-projection:%s@." value
  | Exit.Error cause ->
      Format.eprintf "map projection failed: %a@." (Cause.pp pp_error) cause;
      exit 1
