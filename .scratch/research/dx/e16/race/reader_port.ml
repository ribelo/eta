open Eta

type error =
  [ `Closed
  | `Invalid_user of string ]

type clock = { now_ms : unit -> int }
type users = { first : string; second : string }

type env = {
  clock : clock;
  released : bool ref;
  users : users;
}

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

let with_user_db body env =
  Effect.with_resource ~acquire:(User_db.open_ env.clock env.released)
    ~release:User_db.close (fun db -> Reader.run env (body db))

let users = Reader.map (fun env -> env.users) Reader.ask
let lookup db user_id = Reader.lift (User_db.lookup db user_id)

let program =
  let open Reader.Syntax in
  with_user_db @@ fun db ->
  let* users = users in
  let* first = lookup db users.first in
  let+ second = lookup db users.second in
  (first, second)

let run () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let released = ref false in
  let env =
    {
      clock = { now_ms = (fun () -> 42) };
      released;
      users = { first = "alice"; second = "bob" };
    }
  in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (Reader.run env program) with
  | Exit.Ok result when !released -> result
  | Exit.Ok _ -> failwith "Reader port did not release the database"
  | Exit.Error cause ->
      failwith (Format.asprintf "Reader failed: %a" (Cause.pp pp_error) cause)
