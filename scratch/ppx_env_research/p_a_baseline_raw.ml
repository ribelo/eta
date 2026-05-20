open Effet
open Services

let current_user () =
  Effect.sync "auth.current_user" (fun env ->
    Auth.current_user env#auth)

let current_user_logged () =
  Effect.sync "auth.current_user_logged" (fun env ->
    let user = Auth.current_user env#auth in
    Log.info env#log ("user=" ^ user);
    user)

let env ~auth ~log =
  object
    method auth = auth
    method log = log
  end

let run () =
  let log = Log.create () in
  let value = run (env ~auth:(auth "alice") ~log) (current_user_logged ()) in
  value, log.lines

