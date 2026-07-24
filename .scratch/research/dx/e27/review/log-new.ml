open Eta

let pp_db_find id fmt = Format.fprintf fmt "db.find %d" id

let db_find id =
  Effect.logf (pp_db_find id)

let retry ~table ~ms =
  Effect.logf ~level:Capabilities.Debug ~attrs:[ ("table", table) ] (fun fmt ->
      Format.fprintf fmt "retrying in %d ms" ms)

let request_done ~request_id ~rows =
  Effect.logf ~attrs:[ ("request.id", request_id) ] (fun fmt ->
      Format.fprintf fmt "request completed with %d rows" rows)
