open Effet
open Services

let current_user () =
  [%effet.sync "auth.current_user" (auth : Auth.t) (Auth.current_user auth)]

let current_user_logged () =
  [%effet.sync "auth.current_user_logged" ((auth : Auth.t), (log : Log.t))
    (let user = Auth.current_user auth in
     Log.info log ("user=" ^ user);
     user)]

let current_user_async () =
  [%effet.async "auth.current_user_async" (auth : Auth.t)
    (Auth.current_user auth)]

let run () =
  let log = Log.create () in
  let env =
    object
      method auth = auth "alice"
      method log = log
    end
  in
  let value = run env (current_user_logged ()) in
  value, log.lines

