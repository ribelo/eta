(* W1 against new names: same program as w1-old.ml. *)
open Eta

module Db = struct
  let find id : ((string, [ `Not_found ]) result, [ `Not_found ]) Effect.t =
    if id = 42 then Effect.pure (Ok "alice")
    else if id < 0 then Effect.sync (fun () -> failwith "db crashed")
    else Effect.pure (Error `Not_found)
end

let read_user id =
  Db.find id
  |> Effect.bind Effect.from_result
  |> Effect.fold ~ok:Fun.id ~error:(function `Not_found -> "anonymous")

(* Expected: id=42 -> "alice"; id=0 -> "anonymous"; id=-1 -> Die defect. *)
