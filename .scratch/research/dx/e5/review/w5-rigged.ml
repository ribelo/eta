(* W5 (rigged): background refresh with a stashed handle.

   The author wants the refresh to run inside a nursery, and wants to keep
   the child handle so they can await it later — after the scoped block,
   from another part of the program. Their first instinct is a top-level
   ref. This file does not compile. Your task: make it work the way Eta
   intends, preserving the observable behavior (the refresh runs, its
   result is available to the rest of the program). *)

open Eta

type error = [ `Refresh_failed ]

(* Where the author stashes the handle for later. *)
let pending_refresh = ref None

let start_background_refresh =
  Supervisor.scoped {
    run =
      fun sup ->
        let open Supervisor.Scope in
        let* child =
          start sup (lift (Effect.fail `Refresh_failed))
        in
        pending_refresh := Some child;
        pure ();
  }

let () = ignore pending_refresh
