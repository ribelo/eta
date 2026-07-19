open Eta

type error = [ `Missing_key of string ]
[@@deriving eta_error]

let read_config key =
  if String.equal key "db.url" then Ok "sqlite://app.db"
  else Error (`Missing_key key)

let program key =
  Eta_blocking.run_result ~name:"config.read" (fun () -> read_config key)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program "db.url") with
  | Exit.Ok value -> Format.printf "blocking:%s@." value
  | Exit.Error cause ->
      Format.eprintf "blocking failed: %a@." (Cause.pp pp_error) cause;
      exit 1
