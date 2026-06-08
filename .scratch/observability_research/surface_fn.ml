(* Surface B: Effect.fn smart constructor (TS-Effect-style). *)

open Obs_lib

module Db = struct let query (s : string) = "row(" ^ s ^ ")" end
let env = object method db = Db.query end
let db_q sql = Effect.sync (fun env -> env#db sql)

(* ---- B.1: fn as prefix sugar ---- *)
let fn_prefix id =
  Effect.fn __POS__ __FUNCTION__ (db_q id)

(* ---- B.2: fn at end of pipe ---- *)
let fn_pipe id =
  db_q id
  |> Effect.fn __POS__ __FUNCTION__

(* ---- B.3: fn + extra annotations ---- *)
let fn_with_attrs id =
  db_q id
  |> Effect.annotate ~key:"user_id" ~value:id
  |> Effect.fn __POS__ __FUNCTION__

(* ---- B.4: fn wrapping a multi-step body ---- *)
let fn_multistep id =
  let body =
    let open Effect in
    let* row = db_q id in
    let* _ = db_q ("verify:" ^ row) in
    pure row
  in
  body |> Effect.fn __POS__ __FUNCTION__

(* ---- B.5: explicit name override (don't use __FUNCTION__) ---- *)
let fn_explicit_name id =
  db_q id |> Effect.fn __POS__ "user-fetch"

let run_and_dump label e =
  let tracer = Tracer.make () in
  let _ = interpret ~tracer ~env e in
  Printf.printf "==== %s ====\n%s\n" label (Tracer.dump tracer)

let main () =
  run_and_dump "B.1 fn_prefix"       (fn_prefix "42");
  run_and_dump "B.2 fn_pipe"         (fn_pipe "42");
  run_and_dump "B.3 fn_with_attrs"   (fn_with_attrs "42");
  run_and_dump "B.4 fn_multistep"    (fn_multistep "42");
  run_and_dump "B.5 fn_explicit"     (fn_explicit_name "42")
