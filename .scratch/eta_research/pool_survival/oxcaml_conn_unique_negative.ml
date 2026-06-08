type ('a, 'err) eff =
  | Pure of 'a
  | Fail of 'err

type conn = { id : int }
type t = { mutable slot : conn option }

let with_connection (pool : t)
    (f : conn @ local unique -> (unit, [> `No_conn ]) eff) =
  match pool.slot with
  | None -> Fail `No_conn
  | Some conn -> f conn
