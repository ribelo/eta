open Eta

type db = {
  name : string;
  attempts : int ref;
  mutable closed : bool;
}

let acquire_db () =
  Ok { name = "primary"; attempts = ref 0; closed = false }

let release_db db =
  db.closed <- true;
  Ok ()

let load_user db id =
  if db.closed then Error `Db_closed
  else (
    incr db.attempts;
    if !(db.attempts) < 2 then Error `Db_unavailable
    else Ok (Printf.sprintf "%s:user:%s" db.name id))

let pp_error fmt = function
  | `Db_closed -> Format.pp_print_string fmt "db-closed"
  | `Db_unavailable -> Format.pp_print_string fmt "db-unavailable"

let program id =
  let open Syntax in
  let acquire =
    Effect.sync acquire_db
    |> Effect.flatten_result
  in
  let release db =
    Effect.sync (fun () -> release_db db)
    |> Effect.flatten_result
  in
  let@ db = Effect.with_resource ~acquire ~release in
  Effect.sync (fun () -> load_user db id)
  |> Effect.flatten_result
  |> Effect.retry (Schedule.recurs 3) (function
       | `Db_unavailable -> true
       | `Db_closed -> false)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program "42") with
  | Exit.Ok user -> Format.printf "resource:%s@." user
  | Exit.Error cause ->
      Format.eprintf "resource failed: %a@." (Cause.pp pp_error) cause;
      exit 1
