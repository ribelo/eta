open Eta
open Frame

type behavior = {
  rst_after_headers : bool;
  block_writes : bool;
  held_tags : int list;
}

type t = {
  mutex : Eio.Mutex.t;
  condition : Eio.Condition.t;
  inbound : Frame.t Queue.t;
  mutable writes : Frame.t list;
  mutable closed : bool;
  mutable write_started : int;
  data_writes : int Atomic.t;
  rst_writes : int Atomic.t;
  ping_writes : int Atomic.t;
  behavior : behavior;
}

let create ?(rst_after_headers = false) ?(block_writes = false)
    ?(held_tags = []) () =
  {
    mutex = Eio.Mutex.create ();
    condition = Eio.Condition.create ();
    inbound = Queue.create ();
    writes = [];
    closed = false;
    write_started = 0;
    data_writes = Atomic.make 0;
    rst_writes = Atomic.make 0;
    ping_writes = Atomic.make 0;
    behavior = { rst_after_headers; block_writes; held_tags };
  }

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let is_held t tag = List.exists (( = ) tag) t.behavior.held_tags

let enqueue_inbound_locked t frame =
  Queue.push frame t.inbound;
  Eio.Condition.broadcast t.condition

let response_locked t ~stream_id ~tag =
  enqueue_inbound_locked t (Headers { stream_id; tag; end_stream = true })

let handle_client_frame_locked t = function
  | Frame.Headers { stream_id; tag; end_stream } ->
      if t.behavior.rst_after_headers then
        enqueue_inbound_locked t
          (Rst_stream { stream_id; error = Refused_stream })
      else if end_stream && not (is_held t tag) then
        response_locked t ~stream_id ~tag
  | Data { stream_id; tag; end_stream; _ } ->
      if end_stream && not (is_held t tag) then response_locked t ~stream_id ~tag
  | Rst_stream _ | Ping _ | Window_update _ -> ()

let write_frame_sync t frame =
  Eio.Mutex.use_rw ~protect:false t.mutex @@ fun () ->
  t.write_started <- t.write_started + 1;
  Eio.Condition.broadcast t.condition;
  while t.behavior.block_writes && not t.closed do
    Eio.Condition.await t.condition t.mutex
  done;
  if t.closed then `Closed
  else (
    t.writes <- frame :: t.writes;
    (match frame with
    | Data _ -> Atomic.incr t.data_writes
    | Rst_stream _ -> Atomic.incr t.rst_writes
    | Ping _ -> Atomic.incr t.ping_writes
    | Headers _ | Window_update _ -> ());
    handle_client_frame_locked t frame;
    `Ok)

let write_frame t frame =
  Effect.sync (fun () -> write_frame_sync t frame)
  |> Effect.bind (function `Ok -> Effect.unit | `Closed -> Effect.fail `Socket_closed)

let read_frame_sync t =
  Eio.Mutex.use_rw ~protect:false t.mutex @@ fun () ->
  while Queue.is_empty t.inbound && not t.closed do
    Eio.Condition.await t.condition t.mutex
  done;
  if Queue.is_empty t.inbound then `Closed else `Frame (Queue.take t.inbound)

let read_frame t =
  Effect.sync (fun () -> read_frame_sync t)
  |> Effect.bind (function
       | `Frame frame -> Effect.pure frame
       | `Closed -> Effect.fail `Socket_closed)

let grant_window t ~stream_id ~bytes =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  enqueue_inbound_locked t (Window_update { stream_id; bytes })

let close t =
  with_lock t @@ fun () ->
  t.closed <- true;
  Eio.Condition.broadcast t.condition

let wait_write_started t =
  Effect.sync @@ fun () ->
  Eio.Mutex.use_rw ~protect:false t.mutex @@ fun () ->
  while t.write_started = 0 && not t.closed do
    Eio.Condition.await t.condition t.mutex
  done

let writes t = with_lock t @@ fun () -> List.rev t.writes

let count_writes t pred =
  writes t |> List.fold_left (fun acc frame -> if pred frame then acc + 1 else acc) 0

let data_writes t = Atomic.get t.data_writes
let rst_writes t = Atomic.get t.rst_writes
let ping_writes t = Atomic.get t.ping_writes
