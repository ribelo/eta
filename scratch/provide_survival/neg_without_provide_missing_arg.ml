(* MUST FAIL when compiled manually.

   Property: ordinary OCaml parameter passing exposes a missing service as a
   missing function argument rather than as an env-row mismatch. *)

open Effet
open Provide_survival

let _ : (<  >, string, string) Effect.t =
  Without_provide_sandbox.child
