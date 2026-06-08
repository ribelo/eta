(* Surface D: deliberately wrong-ordered annotations. Tests the
   pending-attrs fix in obs_lib.ml — Annotate placed OUTSIDE Named
   (closer to outermost in pipe order) should still attach via the
   pending buffer. *)

open Obs_lib

module Db = struct let query (s : string) = "row(" ^ s ^ ")" end
let env = object method db = Db.query end
let db_q sql = Effect.sync (fun env -> env#db sql)

(* Annotate OUTSIDE Named (annotate after named in pipe). With the
   pending buffer, the attr should still attach. *)
let wrong_order id =
  db_q id
  |> Effect.named "main"                       (* opens span *)
  |> Effect.annotate ~key:"x" ~value:id        (* OUTSIDE the named span *)

(* Annotate before named (correct/idiomatic ordering). *)
let right_order id =
  db_q id
  |> Effect.annotate ~key:"x" ~value:id
  |> Effect.named "main"

(* Mixed: some inside, some outside. *)
let mixed id =
  db_q id
  |> Effect.annotate ~key:"inner" ~value:"yes"
  |> Effect.named "main"
  |> Effect.annotate ~key:"outer" ~value:"yes"

let main () =
  let run label e =
    let tracer = Tracer.make () in
    let _ = interpret ~tracer ~env e in
    Printf.printf "==== %s ====\n%s" label (Tracer.dump tracer)
  in
  run "wrong_order" (wrong_order "42");
  run "right_order" (right_order "42");
  run "mixed"       (mixed "42")
