open Eta

type session = {
  name : string;
  mutable closed : bool;
}

type error = [ `Session_closed ]

let open_session () =
  Ok { name = "main"; closed = false }

let close_session session =
  session.closed <- true;
  Ok ()

let load session key =
  Effect.sync (fun () ->
      if session.closed then Error `Session_closed
      else Ok (session.name ^ ":" ^ key))
  |> Effect.flatten_result

let session_scope released =
  Effect.acquire_release
    ~acquire:
      (Effect.sync open_session
       |> Effect.flatten_result)
    ~release:(fun session ->
      Effect.sync (fun () ->
          released := true;
          close_session session)
      |> Effect.flatten_result)

let program released =
  let open Syntax in
  Effect.scoped
    (let* session = session_scope released in
     let* config = Effect.named "load.config" (load session "config") in
     let* profile = Effect.named "load.profile" (load session "profile") in
     let+ still_open = Effect.sync (fun () -> not session.closed) in
     (config, profile, still_open))

let pp_error fmt = function
  | `Session_closed -> Format.pp_print_string fmt "session-closed"

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
