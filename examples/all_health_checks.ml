open Eta

type error = [ `Check_failed of string ]

let check = function
  | "search" -> Effect.fail (`Check_failed "search")
  | name -> Effect.named ("health." ^ name) (Effect.pure name)

let all_ok =
  [ "db"; "cache"; "queue" ] |> List.map check |> Effect.all

let one_failed =
  [ "db"; "search"; "cache" ] |> List.map check |> Effect.all

let pp_error fmt = function
  | `Check_failed name -> Format.fprintf fmt "check-failed:%s" name

let ok_or_exit = function
  | Exit.Ok values -> String.concat "," values
  | Exit.Error cause ->
      Format.eprintf "unexpected all ok exit: %a@." (Cause.pp pp_error) cause;
      exit 1

let failed_or_exit = function
  | Exit.Error (Cause.Fail (`Check_failed name)) -> "check-failed:" ^ name
  | Exit.Error cause ->
      Format.eprintf "unexpected all failure exit: %a@." (Cause.pp pp_error)
        cause;
      exit 1
  | Exit.Ok _ -> failwith "all health checks expected a typed failure"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ok = Eta_eio.Runtime.run rt all_ok |> ok_or_exit in
  let failed = Eta_eio.Runtime.run rt one_failed |> failed_or_exit in
  Format.printf "all-health:ok=%s failure=%s@." ok failed
