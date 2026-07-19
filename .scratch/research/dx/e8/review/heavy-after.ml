open Eta

type conn = {
  id : int;
  mutable closed : bool;
}

type error =
  [ `Pool_shutdown
  | `Pool_shutdown_timeout
  | `Query_failed of string ]

let acquire opened =
  Effect.sync (fun () ->
      incr opened;
      { id = !opened; closed = false })

let release closed conn =
  Effect.sync (fun () ->
      if not conn.closed then (
        conn.closed <- true;
        incr closed))

let query conn label =
  [%eta.result "pool.query"
    (if conn.closed then Error (`Query_failed "closed connection")
     else Ok (Printf.sprintf "conn:%d:%s" conn.id label))]

let program opened closed =
  let open Syntax in
  let* pool =
    Pool.create ~name:"primary" ~kind:"example" ~max_size:1
      ~acquire:(acquire opened) ~release:(release closed) ()
  in
  let* first = Pool.with_resource pool (fun conn -> query conn "first") in
  let* second = Pool.with_resource pool (fun conn -> query conn "second") in
  let before_shutdown = Pool.stats pool in
  let* () = Pool.shutdown pool in
  let after_shutdown = Pool.stats pool in
  Effect.pure (first, second, before_shutdown, after_shutdown)
