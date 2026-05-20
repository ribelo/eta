(* Must fail during PPX expansion:
   duplicate capability names are rejected before type checking. *)

open Ppx_env_research.Services

let bad () =
  [%effet.sync "bad.duplicate" ((auth : Auth.t), (auth : Auth.t))
    (Auth.current_user auth)]

