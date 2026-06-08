(* Surface A: pipe-friendly named/annotate, magic identifiers at call sites.
   Closest to the user's stated preference. *)

open Obs_lib

(* Setup: a fake DB service. *)
module Db = struct
  let query (s : string) = "row(" ^ s ^ ")"
end

let env = object method db = Db.query end

(* ---- minimal helpers without auto-naming ---- *)

let db_q sql = Effect.sync (fun env -> env#db sql)

(* ---- A.1: bare named ---- *)
let bare_named id =
  db_q id |> Effect.named "fetch_user_v1"

(* ---- A.2: __FUNCTION__ for auto-name, __POS__ for loc ---- *)
let auto_name id =
  let pos = __POS__ in
  let name = __FUNCTION__ in
  db_q id
  |> Effect.annotate ~key:"loc" ~value:(Printf.sprintf "%s:%d"
    (let (f,_,_,_) = pos in f) (let (_,l,_,_) = pos in l))
  |> Effect.named name

(* ---- A.3: same idea, more compact via [here_attr] ---- *)
let compact id =
  db_q id
  |> Effect.here_attr __POS__
  |> Effect.named __FUNCTION__

(* ---- A.4: stacking multiple decorators ---- *)
let stacked id =
  db_q id
  |> Effect.annotate ~key:"user_id" ~value:id
  |> Effect.annotate ~key:"stage"   ~value:"db.fetch"
  |> Effect.here_attr __POS__
  |> Effect.named __FUNCTION__

(* ---- A.5: decorating a third-party effect we didn't write ---- *)
let decorated_third_party id : (_, _, string) Effect.t =
  db_q id
  |> Effect.named "wrapped_external"
  |> Effect.annotate ~key:"source" ~value:"third-party"
  |> Effect.here_attr __POS__

(* ---- run them and dump traces ---- *)
let run_and_dump label e =
  let tracer = Tracer.make () in
  let _ = interpret ~tracer:tracer ~env e in
  Printf.printf "==== %s ====\n%s\n" label (Tracer.dump tracer)

let main () =
  run_and_dump "A.1 bare_named"   (bare_named "42");
  run_and_dump "A.2 auto_name"    (auto_name "42");
  run_and_dump "A.3 compact"      (compact "42");
  run_and_dump "A.4 stacked"      (stacked "42");
  run_and_dump "A.5 third_party"  (decorated_third_party "42")
