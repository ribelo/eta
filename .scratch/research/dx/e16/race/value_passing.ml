open Eta

type error =
  [ `Closed
  | `Invalid_user of string ]

type clock = { now_ms : unit -> int }
type users = { first : string; second : string }

let pp_error ppf (error : error) =
  match error with
  | `Closed -> Format.pp_print_string ppf "closed"
  | `Invalid_user user -> Format.fprintf ppf "invalid user: %s" user

module User_db = struct
  type t = {
    clock : clock;
    released : bool ref;
  }

  let open_ clock released =
    Effect.sync_result (fun () -> Ok { clock; released })

  let close db = Effect.sync (fun () -> db.released := true)

  let lookup db user_id =
    Effect.sync_result (fun () ->
        if !(db.released) then Error `Closed
        else if String.equal user_id "" then Error (`Invalid_user "empty")
        else Ok (Printf.sprintf "%s@%d" user_id (db.clock.now_ms ())))
end

let with_user_db clock released =
  Effect.with_resource ~acquire:(User_db.open_ clock released)
    ~release:User_db.close

let program clock released users =
  let open Syntax in
  let@ db = with_user_db clock released in
  let* first = User_db.lookup db users.first in
  let+ second = User_db.lookup db users.second in
  (first, second)

let run () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let released = ref false in
  let clock = { now_ms = (fun () -> 42) } in
  let users = { first = "alice"; second = "bob" } in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program clock released users) with
  | Exit.Ok result when !released -> result
  | Exit.Ok _ -> failwith "value-passing port did not release the database"
  | Exit.Error cause ->
      failwith (Format.asprintf "value-passing failed: %a" (Cause.pp pp_error) cause)
