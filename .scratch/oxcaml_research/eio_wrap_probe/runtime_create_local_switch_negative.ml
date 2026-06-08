(* Phase 3 real-runtime shape: accepting the outer Eio switch as [@ local]
   does not work with the current runtime record because the runtime stores
   that switch for daemon forks and later drain semantics. *)

type t = { outer_sw : Eio.Switch.t }

let create ~(sw : Eio.Switch.t @ local) = { outer_sw = sw }

let with_runtime body = Eio.Switch.run (fun sw -> body (create ~sw))

let () = with_runtime ignore
