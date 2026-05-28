open Eta

type conn = { id : int }

module Local_pool : sig
  type t
  type borrow

  val create : conn -> t
  val id : borrow @ local -> int

  val with_connection :
    t ->
    (borrow @ local unique -> ('a, ([> `No_conn ] as 'err)) Effect.t) ->
    ('a, 'err) Effect.t
end = struct
  type borrow = { conn : conn @@ global aliased }
  type t = { mutable slot : conn option }

  let create conn = { slot = Some conn }
  let id (borrow @ local) = borrow.conn.id

  let with_connection pool f =
    match pool.slot with
    | None -> Effect.fail `No_conn
    | Some conn ->
        let local_ borrow = { conn } in
        f borrow
end

let bad_capture pool =
  let ( let@ ) f k = f k in
  let@ borrow = Local_pool.with_connection pool in
  Effect.named "captures-local-borrow" (Effect.sync (fun () -> Local_pool.id borrow))
