open Eta

type error = [ `Cache_miss ]
[@@deriving eta_error]

let cache_lookup =
  Effect.fail `Cache_miss

let recovered =
  cache_lookup |> Effect.fold ~ok:Fun.id ~error:(function `Cache_miss -> "fallback")

let defect =
  Effect.sync (fun () -> failwith "boom")
  |> Effect.fold ~ok:Fun.id ~error:(function `Cache_miss -> "fallback")

let ok_or_exit = function
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "unexpected recovery exit: %a@." (Cause.pp pp_error)
        cause;
      exit 1

let defect_or_exit = function
  | Exit.Error (Cause.Die _) -> "defect-not-caught"
  | Exit.Error cause ->
      Format.eprintf "unexpected defect exit: %a@." (Cause.pp pp_error) cause;
      exit 1
  | Exit.Ok _ -> failwith "catch recovery expected defect to remain uncaught"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let recovered_value = Eta_eio.Runtime.run rt recovered |> ok_or_exit in
  let defect_value = Eta_eio.Runtime.run rt defect |> defect_or_exit in
  Format.printf "catch-recovery:recovered=%s defect=%s@." recovered_value
    defect_value
