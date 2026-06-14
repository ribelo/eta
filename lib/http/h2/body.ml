(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Reader = struct
  type state =
    | Open
    | Received_eof
    | Closed

  type chunk = Bigstringaf.t * int * int

  type callbacks = {
    on_read : Bigstringaf.t -> off:int -> len:int -> unit;
    on_eof : unit -> unit;
  }

  type t = {
    mutable state : state;
    pending : chunk Queue.t;
    mutable callbacks : callbacks option;
    mutable consume_fn : (int -> unit) option;
  }

  type read_result =
    | Ok of Bigstringaf.t * int * int
    | Eof
    | Error of Error_code.t

  let create () =
    {
        state = Open;
        pending = Queue.create ();
        callbacks = None;
        consume_fn = None;
      }

  let set_consume_fn t fn = t.consume_fn <- Some fn

  let deliver t on_read buf ~off ~len =
    on_read buf ~off ~len;
    Option.iter (fun fn -> fn len) t.consume_fn

  let is_closed t =
    match t.state with
    | Closed -> true
    | Received_eof -> Queue.is_empty t.pending
    | Open -> false

  let close t =
    if t.state <> Closed then (
      t.state <- Closed;
      Queue.clear t.pending;
      match t.callbacks with
      | Some { on_eof; _ } ->
          t.callbacks <- None;
          on_eof ()
      | None -> ())

  let schedule_read t ~on_read ~on_eof =
    match Queue.take_opt t.pending with
    | Some (buf, off, len) -> deliver t on_read buf ~off ~len
    | None -> (
        match t.state with
        | Open ->
            if Option.is_some t.callbacks then
              invalid_arg "Eta_http.H2.Body.Reader.schedule_read: read already scheduled";
            t.callbacks <- Some { on_read; on_eof }
        | Received_eof | Closed -> on_eof ())

  let feed t buf ~off ~len =
    if len > 0 then
      match t.state with
      | Open -> (
          match t.callbacks with
          | Some { on_read; _ } ->
              t.callbacks <- None;
              deliver t on_read buf ~off ~len
          | None -> Queue.push (buf, off, len) t.pending)
      | Received_eof | Closed -> ()

  let feed_eof t =
    match t.state with
    | Open ->
        t.state <- Received_eof;
        if Queue.is_empty t.pending then (
          match t.callbacks with
          | Some { on_eof; _ } ->
              t.callbacks <- None;
              on_eof ()
          | None -> ())
    | Received_eof | Closed -> ()
end

module Writer = struct
  type t = {
    mutable closed : bool;
    mutable write_fn : (Bigstringaf.t -> off:int -> len:int -> unit) option;
    mutable flush_fn : ((unit -> unit) -> unit) option;
    mutable close_callback : (unit -> unit) option;
    pending : (Bigstringaf.t * int * int) Queue.t;
    mutable flush_fns : (unit -> unit) list;
  }

  let create () =
    {
      closed = false;
      write_fn = None;
      flush_fn = None;
      close_callback = None;
      pending = Queue.create ();
      flush_fns = [];
    }

  let is_closed t = t.closed

  let set_write_fn t fn =
    t.write_fn <- Some fn;
    while not (Queue.is_empty t.pending) do
      let buf, off, len = Queue.pop t.pending in
      fn buf ~off ~len
    done

  let close_callback t = ref None

  let set_close_callback t fn =
    t.close_callback <- Some fn

  let set_flush_fn t fn =
    t.flush_fn <- Some fn;
    let fns = t.flush_fns in
    t.flush_fns <- [];
    List.iter fn (List.rev fns)

  let write_bigstring t buf ~off ~len =
    if t.closed then Error Error_code.Stream_closed
    else
      match t.write_fn with
      | Some fn ->
          fn buf ~off ~len;
          Ok ()
      | None ->
          Queue.push (buf, off, len) t.pending;
          Ok ()

  let write_string t s =
    let len = String.length s in
    let buf = Bigstringaf.create len in
    Bigstringaf.blit_from_string s ~src_off:0 buf ~dst_off:0 ~len;
    write_bigstring t buf ~off:0 ~len

  let write_bytes t b ~off ~len =
    let buf = Bigstringaf.create len in
    Bigstringaf.blit_from_bytes b ~src_off:off buf ~dst_off:0 ~len;
    write_bigstring t buf ~off:0 ~len

  let flush t fn =
    if t.closed then fn ()
    else
      match t.flush_fn with
      | Some flush_fn -> flush_fn fn
      | None -> t.flush_fns <- fn :: t.flush_fns

  let run_flush_callbacks t =
    let fns = t.flush_fns in
    t.flush_fns <- [];
    List.iter (fun f -> f ()) (List.rev fns)

  let close t =
    if not t.closed then (
      t.closed <- true;
      t.write_fn <- None;
      Queue.clear t.pending;
      let cb = t.close_callback in
      t.close_callback <- None;
      run_flush_callbacks t;
      Option.iter (fun f -> f ()) cb)
end
