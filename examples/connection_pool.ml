open Eta

type conn = {
  id : int;
  mutable closed : bool;
}

type error =
  [ `Pool_shutdown
  | `Pool_shutdown_timeout
  | `Query_failed of string ]
[@@deriving eta_error]

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

let () =
  Eio_main.run @@ fun stdenv ->
  Eio.Switch.run @@ fun sw ->
  let opened = ref 0 in
  let closed = ref 0 in
  let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
  match Eta_eio.Runtime.run rt (program opened closed) with
  | Exit.Ok (first, second, before_shutdown, after_shutdown) -> (
      match
        ( before_shutdown.Pool.opened,
          before_shutdown.Pool.idle,
          before_shutdown.Pool.closed,
          after_shutdown.Pool.closed,
          !opened,
          !closed )
      with
      | 1, 1, 0, 1, 1, 1 ->
          Format.printf
            "pool:%s,%s opened=%d idle-before=%d closed-after=%d@." first
            second before_shutdown.Pool.opened before_shutdown.Pool.idle
            after_shutdown.Pool.closed
      | _ ->
          Format.eprintf "pool produced unexpected state@.";
          exit 1)
  | Exit.Error cause ->
      Format.eprintf "pool failed: %a@." (Cause.pp pp_error) cause;
      exit 1
