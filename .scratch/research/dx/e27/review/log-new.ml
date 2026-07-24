open Eta

let db_find id =
  Effect.logf "db.find %d" id

let retry ~table ~ms =
  Effect.logf ~level:Capabilities.Debug ~attrs:[ ("table", table) ]
    "retrying in %d ms" ms

let request_done ~request_id ~rows =
  Effect.logf ~attrs:[ ("request.id", request_id) ]
    "request completed with %d rows" rows
