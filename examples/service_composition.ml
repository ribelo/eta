open Eta

type error =
  [ `Closed
  | `Invalid_user of string ]
[@@deriving eta_error]

type clock = { now_ms : unit -> int }

module User_db = struct
  type t = {
    clock : clock;
    released : bool ref;
  }

  let open_ clock released =
    Effect.sync_result (fun () -> Ok { clock; released })

  let close db =
    Effect.sync (fun () -> db.released := true)

  let lookup db user_id =
    [%eta.result "user.lookup"
      (if !(db.released) then Error `Closed
       else if String.equal user_id "" then Error (`Invalid_user "empty")
       else Ok (Printf.sprintf "%s@%d" user_id (db.clock.now_ms ())))]
end

let with_user_db clock released =
  Effect.with_resource ~acquire:(User_db.open_ clock released)
    ~release:User_db.close

let program clock released =
  let open Syntax in
  let@ db = with_user_db clock released in
  let* alice = User_db.lookup db "alice" in
  let+ bob = User_db.lookup db "bob" in
  (alice, bob)

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let released = ref false in
  let clock = { now_ms = (fun () -> 42) } in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program clock released) with
  | Exit.Ok (alice, bob) ->
      Format.printf "service-composition:alice=%s bob=%s released=%b@." alice
        bob !released
  | Exit.Error cause ->
      Format.eprintf "service composition failed: %a@." (Cause.pp pp_error)
        cause;
      Stdlib.exit 1
