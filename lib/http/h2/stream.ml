(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type id = int

type state =
  | Idle
  | Reserved_local
  | Reserved_remote
  | Open
  | Half_closed_local
  | Half_closed_remote
  | Closed

type error =
  | Stream_closed
  | Protocol_violation of string
  | Flow_control_violation of string

type chunk = {
  buf : Bigstringaf.t;
  mutable off : int;
  mutable len : int;
}

type t = {
  id : id;
  mutable state : state;
  send_window : Window.t;
  recv_window : Window.t;
  request_body : Body.Reader.t;
  pending_data : chunk Queue.t;
  mutable total_pending : int;
  mutable drain_callbacks : (unit -> unit) list;
  mutable recv_window_unnotified : int;
  mutable send_end_stream : bool;
  mutable sent_end_stream : bool;
  mutable recv_end_stream : bool;
  mutable trailers : (string * string) list option;
  mutable reset_local : Error_code.t option;
  mutable reset_remote : Error_code.t option;
}

let id t = t.id
let state t = t.state
let is_open t = t.state = Open
let is_closed t = t.state = Closed
let send_end_stream t = t.send_end_stream
let sent_end_stream t = t.sent_end_stream
let recv_end_stream t = t.recv_end_stream
let request_body t = t.request_body
let send_window t = t.send_window
let recv_window t = t.recv_window

let note_recv_window_consumed t len =
  if len <= 0 then None
  else (
    t.recv_window_unnotified <- t.recv_window_unnotified + len;
    if t.recv_window_unnotified >= Window.available t.recv_window then (
      let increment = t.recv_window_unnotified in
      t.recv_window_unnotified <- 0;
      Some increment)
    else None)

let create ~id ~initial_send_window ~initial_recv_window =
  {
    id;
    state = Idle;
    send_window = Window.create ~initial:initial_send_window;
    recv_window = Window.create ~initial:initial_recv_window;
    request_body = Body.Reader.create ();
    pending_data = Queue.create ();
    total_pending = 0;
    drain_callbacks = [];
    recv_window_unnotified = 0;
    send_end_stream = false;
    sent_end_stream = false;
    recv_end_stream = false;
    trailers = None;
    reset_local = None;
    reset_remote = None;
  }

let total_pending t = t.total_pending

let run_drain_callbacks t =
  let callbacks = t.drain_callbacks in
  t.drain_callbacks <- [];
  List.iter (fun f -> f ()) (List.rev callbacks)

let notify_drained t =
  if t.total_pending = 0 then run_drain_callbacks t

let on_drained t fn =
  if t.total_pending = 0 then fn ()
  else t.drain_callbacks <- fn :: t.drain_callbacks

let queue_data t buf ~off ~len =
  if len < 0 then Error (Protocol_violation "negative data length")
  else if t.state = Closed || t.state = Half_closed_local then
    Error Stream_closed
  else (
    Queue.push { buf; off; len } t.pending_data;
    t.total_pending <- t.total_pending + len;
    Ok ())

let mark_send_end_stream t =
  if not t.send_end_stream then t.send_end_stream <- true

let mark_sent_end_stream t =
  if not t.sent_end_stream then t.sent_end_stream <- true

let mark_recv_end_stream t =
  if not t.recv_end_stream then t.recv_end_stream <- true

let set_trailers t trailers = t.trailers <- Some trailers
let has_trailers t = Option.is_some t.trailers

let take_trailers t =
  let trailers = t.trailers in
  t.trailers <- None;
  trailers

let reset t ~error_code =
  t.reset_local <- Some error_code;
  t.drain_callbacks <- [];
  t.state <- Closed

let reset_by_peer t ~error_code =
  t.reset_remote <- Some error_code;
  t.drain_callbacks <- [];
  t.state <- Closed

let take_pending_data t ~max_len =
  if t.state = Closed then None
  else if Queue.is_empty t.pending_data then None
  else
    let avail = min (Window.available t.send_window) max_len in
    if avail <= 0 then None
    else
      let chunk = Queue.peek t.pending_data in
      let take = min chunk.len avail in
      Window.consume t.send_window take |> ignore;
      if take = chunk.len then (
        ignore (Queue.pop t.pending_data);
        t.total_pending <- t.total_pending - take;
        Some (chunk.buf, chunk.off, chunk.len))
      else (
        let result = Some (chunk.buf, chunk.off, take) in
        chunk.off <- chunk.off + take;
        chunk.len <- chunk.len - take;
        t.total_pending <- t.total_pending - take;
        result)
