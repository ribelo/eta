open Eta

type conn = { id : int }

module Pool : sig
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
        let result = f borrow in
        result
end

let demo () =
  let pool = Pool.create { id = 42 } in
  Pool.with_connection pool (fun borrow -> Effect.pure (Pool.id borrow))

let () = ignore (demo () : (int, [> `No_conn ]) Effect.t)
