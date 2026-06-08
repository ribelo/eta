open Eta

type status = Active | Cancelled | Complete

type stream = {
  id : int;
  tag : int;
  inbound : Frame.t Channel.t;
  window_used : unit Channel.t;
  mutable status : status;
}

type stats = {
  active : int;
  cancelled : int;
  live : int;
  opened : int;
  completed : int;
  remote_resets : int;
  local_resets : int;
  admission_rejected : int;
  max_inflight : int;
}

type t = {
  mutex : Eio.Mutex.t;
  streams : (int, stream) Hashtbl.t;
  max_concurrent : int;
  window_chunks : int;
  mutable next_id : int;
  mutable active : int;
  mutable cancelled : int;
  mutable opened : int;
  mutable completed : int;
  mutable remote_resets : int;
  mutable local_resets : int;
  mutable admission_rejected : int;
  mutable max_inflight : int;
}

let create ~max_concurrent ~window_chunks =
  {
    mutex = Eio.Mutex.create ();
    streams = Hashtbl.create max_concurrent;
    max_concurrent;
    window_chunks;
    next_id = 1;
    active = 0;
    cancelled = 0;
    opened = 0;
    completed = 0;
    remote_resets = 0;
    local_resets = 0;
    admission_rejected = 0;
    max_inflight = 0;
  }

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let inflight t = t.active + t.cancelled

let update_max_inflight t =
  t.max_inflight <- max t.max_inflight (inflight t)

let open_stream t ~tag =
  with_lock t @@ fun () ->
  if inflight t >= t.max_concurrent then (
    t.admission_rejected <- t.admission_rejected + 1;
    `Rejected)
  else
    let id = t.next_id in
    t.next_id <- t.next_id + 2;
    let stream =
      {
        id;
        tag;
        inbound = Channel.create ~capacity:16 ();
        window_used = Channel.create ~capacity:t.window_chunks ();
        status = Active;
      }
    in
    Hashtbl.add t.streams id stream;
    t.active <- t.active + 1;
    t.opened <- t.opened + 1;
    update_max_inflight t;
    `Stream stream

let find t stream_id = with_lock t @@ fun () -> Hashtbl.find_opt t.streams stream_id

let mark_remote_reset t stream_id =
  with_lock t @@ fun () ->
  match Hashtbl.find_opt t.streams stream_id with
  | Some stream when stream.status = Active ->
      stream.status <- Cancelled;
      t.active <- max 0 (t.active - 1);
      t.cancelled <- t.cancelled + 1;
      t.remote_resets <- t.remote_resets + 1;
      update_max_inflight t
  | _ -> ()

let mark_complete t stream =
  with_lock t @@ fun () ->
  if stream.status = Active then stream.status <- Complete

let release t stream =
  let queue_rst =
    with_lock t @@ fun () ->
    let queue_rst = stream.status = Active in
    (match stream.status with
    | Active ->
        t.active <- max 0 (t.active - 1);
        t.local_resets <- t.local_resets + 1
    | Cancelled -> t.cancelled <- max 0 (t.cancelled - 1)
    | Complete -> t.active <- max 0 (t.active - 1));
    Hashtbl.remove t.streams stream.id;
    t.completed <- t.completed + 1;
    queue_rst
  in
  Channel.close stream.inbound;
  Channel.close stream.window_used;
  queue_rst

let close_all t =
  let streams =
    with_lock t @@ fun () ->
    let streams = Hashtbl.to_seq_values t.streams |> List.of_seq in
    Hashtbl.clear t.streams;
    t.active <- 0;
    t.cancelled <- 0;
    streams
  in
  List.iter
    (fun stream ->
      Channel.close stream.inbound;
      Channel.close stream.window_used)
    streams

let stats t =
  with_lock t @@ fun () ->
  {
    active = t.active;
    cancelled = t.cancelled;
    live = Hashtbl.length t.streams;
    opened = t.opened;
    completed = t.completed;
    remote_resets = t.remote_resets;
    local_resets = t.local_resets;
    admission_rejected = t.admission_rejected;
    max_inflight = t.max_inflight;
  }
