(* Must fail during PPX expansion:
   the leaf body mentions env directly instead of using the declared cap list. *)

open Ppx_env_research.Services

let bad () =
  [%effet.sync "bad.env_creep" (auth : Auth.t)
    (Auth.current_user auth ^ Db.query env#db "x")]

