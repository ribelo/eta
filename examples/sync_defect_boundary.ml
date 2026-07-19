open Eta

type error = [ `Unexpected ] [@@deriving eta_error]

let load_ok =
  Effect.sync (fun () -> "config:ok")

let load_defect =
  Effect.sync (fun () -> failwith "config parser bug")

let ok_or_exit = function
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "unexpected sync success exit: %a@." (Cause.pp pp_error)
        cause;
      exit 1

let defect_or_exit = function
  | Exit.Error (Cause.Die _) -> "die"
  | Exit.Error cause ->
      Format.eprintf "unexpected sync defect exit: %a@." (Cause.pp pp_error)
        cause;
      exit 1
  | Exit.Ok _ -> failwith "sync defect boundary expected a defect"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ok = Eta_eio.Runtime.run rt load_ok |> ok_or_exit in
  let defect = Eta_eio.Runtime.run rt load_defect |> defect_or_exit in
  Format.printf "sync-defect:ok=%s defect=%s@." ok defect
