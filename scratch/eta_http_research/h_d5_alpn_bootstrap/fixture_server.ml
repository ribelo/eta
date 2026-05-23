open Eta

type protocol = Pending_connection.protocol = H1 | H2

type h1_conn = { id : int; mutable closed : bool }

type stats = {
  pending_opened : int;
  pending_cancelled : int;
  pending_resolved : int;
  pending_live : int;
  h1_opened : int;
  h1_closed : int;
  h1_requests : int;
  h2_opened : int;
  h2_closed : int;
}

type t = {
  protocol : protocol;
  delay : Duration.t;
  mutex : Eio.Mutex.t;
  mutable next_id : int;
  mutable pendings : Pending_connection.t list;
  mutable pending_opened : int;
  mutable pending_cancelled : int;
  mutable pending_resolved : int;
  mutable h1_opened : int;
  mutable h1_closed : int;
  mutable h1_requests : int;
  mutable h2_opened : int;
  mutable h2_closed : int;
}

let create ?(delay = Duration.ms 10) protocol =
  {
    protocol;
    delay;
    mutex = Eio.Mutex.create ();
    next_id = 1;
    pendings = [];
    pending_opened = 0;
    pending_cancelled = 0;
    pending_resolved = 0;
    h1_opened = 0;
    h1_closed = 0;
    h1_requests = 0;
    h2_opened = 0;
    h2_closed = 0;
  }

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let next_id_locked t =
  let id = t.next_id in
  t.next_id <- t.next_id + 1;
  id

let open_pending t =
  with_lock t @@ fun () ->
  let id = next_id_locked t in
  let pending =
    Pending_connection.create ~id ~protocol:t.protocol ~delay:t.delay
      ~on_cancel:(fun () ->
        with_lock t @@ fun () ->
        t.pending_cancelled <- t.pending_cancelled + 1)
      ~on_resolve:(fun () ->
        with_lock t @@ fun () ->
        t.pending_resolved <- t.pending_resolved + 1)
      ()
  in
  t.pending_opened <- t.pending_opened + 1;
  t.pendings <- pending :: t.pendings;
  pending

let open_h1 t =
  with_lock t @@ fun () ->
  let conn = { id = next_id_locked t; closed = false } in
  t.h1_opened <- t.h1_opened + 1;
  conn

let acquire_h1 t = Effect.sync (fun () -> open_h1 t)

let close_h1 t conn =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  if not conn.closed then (
    conn.closed <- true;
    t.h1_closed <- t.h1_closed + 1)

let record_h1_request t _conn =
  with_lock t @@ fun () -> t.h1_requests <- t.h1_requests + 1

let open_h2 t =
  with_lock t (fun () -> t.h2_opened <- t.h2_opened + 1);
  Fake_multiplex_connection.create ()

let close_h2 t conn =
  with_lock t (fun () -> t.h2_closed <- t.h2_closed + 1);
  Fake_multiplex_connection.close conn

let stats t =
  with_lock t @@ fun () ->
  let pending_live =
    List.fold_left
      (fun acc pending ->
        if Pending_connection.is_live (Pending_connection.state pending) then acc + 1
        else acc)
      0 t.pendings
  in
  {
    pending_opened = t.pending_opened;
    pending_cancelled = t.pending_cancelled;
    pending_resolved = t.pending_resolved;
    pending_live;
    h1_opened = t.h1_opened;
    h1_closed = t.h1_closed;
    h1_requests = t.h1_requests;
    h2_opened = t.h2_opened;
    h2_closed = t.h2_closed;
  }
