open Eta
open Generators

type t = {
  streams : Stream_state.t;
  mutable current : Stream_state.stream option;
  mutable open_streams : Stream_state.stream list;
  mutable next_stream_id : int;
  mutable body_ended : bool;
  mutable rst_seen : bool;
  mutable body_after_rst : int;
  mutable delivered_after_rst : int;
  mutable body_delivered : int;
  mutable trailers_delivered : int;
  mutable early_trailers_rejected : int;
  mutable window : int;
  mutable min_window : int;
  mutable goaway_last_stream_id : int option;
  mutable opened_after_goaway : int;
  mutable rejected_after_goaway : int;
  mutable push_rejected : int;
  mutable connection_error : bool;
  mutable priority_seen : int;
  mutable priority_honored : bool;
  mutable eof_returned : bool;
  mutable exhausted_count : int;
  pool_capacity : int;
  mutable pool_active : int;
  mutable pool_idle : int;
}

let create () =
  {
    streams = Stream_state.create ~max_concurrent:16 ~window_chunks:16;
    current = None;
    open_streams = [];
    next_stream_id = 1;
    body_ended = false;
    rst_seen = false;
    body_after_rst = 0;
    delivered_after_rst = 0;
    body_delivered = 0;
    trailers_delivered = 0;
    early_trailers_rejected = 0;
    window = 65_535;
    min_window = 65_535;
    goaway_last_stream_id = None;
    opened_after_goaway = 0;
    rejected_after_goaway = 0;
    push_rejected = 0;
    connection_error = false;
    priority_seen = 0;
    priority_honored = false;
    eof_returned = false;
    exhausted_count = 0;
    pool_capacity = 4;
    pool_active = 0;
    pool_idle = 0;
  }

let pool_checkout t =
  if t.pool_idle > 0 then (
    t.pool_idle <- t.pool_idle - 1;
    t.pool_active <- t.pool_active + 1)
  else if t.pool_active + t.pool_idle < t.pool_capacity then
    t.pool_active <- t.pool_active + 1

let pool_release t =
  if t.pool_active > 0 then (
    t.pool_active <- t.pool_active - 1;
    if t.pool_idle < t.pool_capacity then t.pool_idle <- t.pool_idle + 1)

let goaway_denies t =
  match t.goaway_last_stream_id with
  | None -> false
  | Some last -> t.next_stream_id > last

let open_stream t =
  if goaway_denies t then (
    t.opened_after_goaway <- t.opened_after_goaway + 1;
    t.rejected_after_goaway <- t.rejected_after_goaway + 1)
  else
    match Stream_state.open_stream t.streams ~tag:t.next_stream_id with
    | `Rejected -> ()
    | `Stream stream ->
        t.current <- Some stream;
        t.open_streams <- stream :: t.open_streams;
        t.next_stream_id <- stream.Stream_state.id + 2;
        pool_checkout t

let release_stream t stream =
  if List.exists (fun s -> s.Stream_state.id = stream.Stream_state.id) t.open_streams then (
      ignore (Stream_state.release t.streams stream : bool);
      t.open_streams <-
        List.filter
          (fun s -> s.Stream_state.id <> stream.Stream_state.id)
          t.open_streams;
      (match t.current with
      | Some current when current.Stream_state.id = stream.Stream_state.id ->
          t.current <- None
      | _ -> ());
      pool_release t)

let release_current t =
  match t.current with
  | None -> pool_release t
  | Some stream -> release_stream t stream

let remote_rst t =
  match t.current with
  | None -> t.rst_seen <- true
  | Some stream ->
      t.rst_seen <- true;
      Stream_state.mark_remote_reset t.streams stream.Stream_state.id

let data t bytes =
  if t.rst_seen then t.body_after_rst <- t.body_after_rst + 1
  else if bytes <= t.window then (
    t.body_delivered <- t.body_delivered + 1;
    t.window <- t.window - bytes;
    t.min_window <- min t.min_window t.window)

let read_body t =
  if (t.body_ended || t.rst_seen) && not t.eof_returned then (
    t.eof_returned <- true;
    t.exhausted_count <- t.exhausted_count + 1)

let apply t = function
  | Open -> open_stream t
  | Headers -> ()
  | Data bytes -> data t bytes
  | End_stream -> t.body_ended <- true
  | Rst_stream -> remote_rst t
  | Cancel -> release_current t
  | Release -> release_current t
  | Window_update bytes ->
      t.window <- t.window + bytes;
      t.min_window <- min t.min_window t.window
  | Goaway last -> t.goaway_last_stream_id <- Some last
  | Push_promise ->
      (* RFC 9113 section 8.4: clients that set SETTINGS_ENABLE_PUSH=0 must
         treat PUSH_PROMISE as a connection error. *)
      t.push_rejected <- t.push_rejected + 1;
      t.connection_error <- true
  | Priority ->
      (* RFC 9113 section 5.3.2: PRIORITY is deprecated; accept and ignore. *)
      t.priority_seen <- t.priority_seen + 1;
      t.priority_honored <- false
  | Trailer ->
      if t.body_ended then t.trailers_delivered <- t.trailers_delivered + 1
      else t.early_trailers_rejected <- t.early_trailers_rejected + 1
  | Read_body -> read_body t

let run ops =
  let t = create () in
  List.iter (apply t) ops;
  t

let finalize t =
  let open_streams = t.open_streams in
  List.iter (release_stream t) open_streams;
  Stream_state.stats t.streams

let pool_consistent t =
  t.pool_active >= 0 && t.pool_idle >= 0
  && t.pool_active + t.pool_idle <= t.pool_capacity
