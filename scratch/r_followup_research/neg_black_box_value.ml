(* Predicted error:
   The module does not match the signature because the open env row and error
   type are weak variables. This defends the finding that reusable public
   env-requiring effects should be thunks, not already-built open-row values. *)

open Effet
open R_followup_research.Services

module Third_party : sig
  val black_box : (< db : db ; .. >, string, string) Effect.t
end = struct
  let black_box =
    Effect.sync "third.black_box" (fun env -> query env#db "child")
end
