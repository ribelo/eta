open Eta

type error =
  [ `Invalid_id of string
  | `Request_timeout ]
[@@deriving eta_error]

let fast =
  Effect.pure "cache-hit"
  |> Effect.timeout_as (Duration.ms 50) ~on_timeout:`Request_timeout

let slow =
  Effect.delay (Duration.ms 50) (Effect.pure "late")
  |> Effect.timeout_as (Duration.ms 1) ~on_timeout:`Request_timeout

let invalid =
  Effect.fail (`Invalid_id "empty")
  |> Effect.timeout_as (Duration.ms 50) ~on_timeout:`Request_timeout

let ok_or_exit label = function
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "unexpected %s exit: %a@." label (Cause.pp pp_error) cause;
      exit 1

let request_timeout_or_exit = function
  | Exit.Error (Cause.Fail `Request_timeout) -> "request-timeout"
  | Exit.Error cause ->
      Format.eprintf "unexpected timeout exit: %a@." (Cause.pp pp_error) cause;
      exit 1
  | Exit.Ok _ -> failwith "timeout policy check failed: expected timeout"

let invalid_or_exit = function
  | Exit.Error (Cause.Fail (`Invalid_id id)) -> "invalid-id:" ^ id
  | Exit.Error cause ->
      Format.eprintf "unexpected invalid exit: %a@." (Cause.pp pp_error) cause;
      exit 1
  | Exit.Ok _ -> failwith "timeout policy check failed: expected invalid id"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let fast_value = Eta_eio.Runtime.run rt fast |> ok_or_exit "fast" in
  let timeout_value = Eta_eio.Runtime.run rt slow |> request_timeout_or_exit in
  let invalid_value = Eta_eio.Runtime.run rt invalid |> invalid_or_exit in
  Format.printf "timeout-policy:fast=%s timeout=%s failure=%s@." fast_value
    timeout_value invalid_value
