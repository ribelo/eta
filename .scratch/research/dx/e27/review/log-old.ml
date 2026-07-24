open Eta

let db_find id =
  Effect.log (Printf.sprintf "db.find %d" id)

let retry ~table ~ms =
  Effect.log ~level:Capabilities.Debug ~attrs:[ ("table", table) ]
    (Printf.sprintf "retrying in %d ms" ms)

let request_done ~request_id ~rows =
  Effect.log ~attrs:[ ("request.id", request_id) ]
    (Printf.sprintf "request completed with %d rows" rows)
