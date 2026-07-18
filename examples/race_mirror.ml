open Eta

type mirror = {
  name : string;
  available : bool;
}

type error = [ `Mirror_down of string ]

let request mirror path =
  Effect.named ("mirror." ^ mirror.name)
    (Effect.sync_result (fun () ->
         if mirror.available then Ok (mirror.name ^ ":" ^ path)
         else Error (`Mirror_down mirror.name)))

let program path =
  Effect.race
    [
      request { name = "primary"; available = false } path;
      request { name = "secondary"; available = true } path;
      request { name = "tertiary"; available = true } path;
    ]

let pp_error fmt = function
  | `Mirror_down name -> Format.fprintf fmt "mirror-down:%s" name

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program "/users/42") with
  | Exit.Ok payload -> Format.printf "race:%s@." payload
  | Exit.Error cause ->
      Format.eprintf "race failed: %a@." (Cause.pp pp_error) cause;
      exit 1
