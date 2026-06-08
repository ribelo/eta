(* Must fail during PPX expansion:
   duplicate runtime env fields are rejected by ppx_effet. *)

open Ppx_env_research.Services

let bad auth =
  [%effet.env { auth = (auth : Auth.t); auth = (auth : Auth.t) }]

