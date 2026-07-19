open Eta

type error = [ `Invalid_id of string ]
[@@deriving eta_error]

let parse_id = function
  | "" -> Error (`Invalid_id "empty")
  | id -> Ok id

let load_user id =
  Effect.pure ("user:" ^ id)

let program raw =
  let open Syntax in
  let* id = Effect.from_result (parse_id raw) in
  load_user id

let ok_or_exit = function
  | Exit.Ok value -> value
  | Exit.Error cause ->
      Format.eprintf "unexpected validation success exit: %a@."
        (Cause.pp pp_error) cause;
      exit 1

let invalid_or_exit = function
  | Exit.Error (Cause.Fail (`Invalid_id id)) -> "invalid-id:" ^ id
  | Exit.Error cause ->
      Format.eprintf "unexpected validation failure exit: %a@."
        (Cause.pp pp_error) cause;
      exit 1
  | Exit.Ok _ -> failwith "validation boundary expected invalid id"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let ok = Eta_eio.Runtime.run rt (program "42") |> ok_or_exit in
  let failure = Eta_eio.Runtime.run rt (program "") |> invalid_or_exit in
  Format.printf "validation-boundary:ok=%s failure=%s@." ok failure
