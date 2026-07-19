open Eta

type session = {
  name : string;
  mutable closed : bool;
}

type error = [ `Session_closed ]
[@@deriving eta_error]

let open_session () =
  Ok { name = "main"; closed = false }

let close_session session =
  session.closed <- true;
  Ok ()

let load session key =
  Effect.sync_result (fun () ->
      if session.closed then Error `Session_closed
      else Ok (session.name ^ ":" ^ key))

let session_scope released =
  Effect.acquire_release
    ~acquire:
      (Effect.sync_result open_session)
    ~release:(fun session ->
      Effect.sync_result (fun () ->
          released := true;
          close_session session))

let program released =
  let open Syntax in
  Effect.with_scope
    (let* session = session_scope released in
     let* config = Effect.named ~error_pp:pp_error "load.config" (load session "config") in
     let* profile = Effect.named ~error_pp:pp_error "load.profile" (load session "profile") in
     let+ still_open = Effect.sync (fun () -> not session.closed) in
     (config, profile, still_open))

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let released = ref false in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program released) with
  | Exit.Ok (config, profile, true) ->
      if not !released then (
        Format.eprintf "session was not released@.";
        exit 1);
      Format.printf "scoped:%s,%s released=%b@." config profile !released
  | Exit.Ok (_, _, false) ->
      Format.eprintf "session closed before scoped body finished@.";
      exit 1
  | Exit.Error cause ->
      Format.eprintf "scoped resource failed: %a@." (Cause.pp pp_error) cause;
      exit 1
