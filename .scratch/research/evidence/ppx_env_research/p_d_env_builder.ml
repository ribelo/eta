open Effet
open Services

let env ~auth ~log =
  [%effet.env { auth = (auth : Auth.t); log = (log : Log.t) }]

let current_user_logged () =
  [%effet.sync "auth.current_user_logged" ((auth : Auth.t), (log : Log.t))
    (let user = Auth.current_user auth in
     Log.info log ("user=" ^ user);
     user)]

let run () =
  let log = Log.create () in
  let value = run (env ~auth:(auth "alice") ~log) (current_user_logged ()) in
  value, log.lines
