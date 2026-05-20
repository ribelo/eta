(* Surface C: nested spans. Tests that named effects inside a pipe-form
   parent compose into a parent/child span tree. *)

open Obs_lib

module Db = struct let query (s : string) = "row(" ^ s ^ ")" end
let env = object method db = Db.query end
let db_q sql = Effect.sync (fun env -> env#db sql)

(* Inner helpers each carry their own name + loc. *)
let inner_db id =
  db_q id |> Effect.here_attr __POS__ |> Effect.named __FUNCTION__

let inner_validate row =
  db_q ("validate:" ^ row)
  |> Effect.here_attr __POS__
  |> Effect.named __FUNCTION__

(* Outer composes them. *)
let outer_fetch id =
  let body =
    let open Effect in
    let* row = inner_db id in
    let* _   = inner_validate row in
    pure row
  in
  body
  |> Effect.annotate ~key:"user_id" ~value:id
  |> Effect.here_attr __POS__
  |> Effect.named __FUNCTION__

let main () =
  let tracer = Tracer.make () in
  let _ = interpret ~tracer ~env (outer_fetch "42") in
  print_endline (Tracer.dump tracer)
