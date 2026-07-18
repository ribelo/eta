open Eta

type error =
  [ `Bad_args of string
  | `Network ]

let parse_id = function
  | "" -> Error (`Bad_args "empty id")
  | id -> Ok id

let user_request id =
  let attempts = ref 0 in
  Effect.sync (fun () ->
      incr attempts;
      if !attempts = 1 then Error `Network
      else Ok (Printf.sprintf "user:%s" id))
  |> Effect.flatten_result

let program args =
  let open Syntax in
  let raw = match args with id :: _ -> id | [] -> "42" in
  let* id = Effect.from_result (parse_id raw) in
  let* user =
    user_request id
    |> Effect.retry ~schedule:(Schedule.recurs 2) ~while_:(function
         | `Network -> true
         | `Bad_args _ -> false)
  in
  Effect.pure ("cli:" ^ user)

let pp_error fmt = function
  | `Bad_args reason -> Format.fprintf fmt "bad-args:%s" reason
  | `Network -> Format.pp_print_string fmt "network"

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  let args = Array.to_list Sys.argv |> List.tl in
  match Eta_eio.Runtime.run rt (program args) with
  | Exit.Ok message -> Format.printf "%s@." message
  | Exit.Error cause ->
      Format.eprintf "cli failed: %a@." (Cause.pp pp_error) cause;
      exit 1
