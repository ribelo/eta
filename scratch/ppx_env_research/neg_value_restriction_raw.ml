(* Must fail:
   an exported raw open-row Effect.t value gets weak variables. The ppx leaf
   examples deliberately use unit -> Effect.t thunks instead. *)

open Effet
open Ppx_env_research.Services

module M : sig
  val current_user : (< auth : Auth.t ; .. >, string, string) Effect.t
end = struct
  let current_user =
    Effect.sync "auth.current_user" (fun env -> Auth.current_user env#auth)
end

