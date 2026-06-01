(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Stream_state = Stream_state
module Security = Security

(* Multiplexer is intentionally socket-free. It adapts ocaml-h2's mutable
   Client_connection callbacks into Eta stream state, while Connection owns the
   actual flow reads/writes and shutdown. Do not add Eio.Flow operations here;
   that keeps connection lifetime and per-stream lifetime auditable separately. *)

type stream = Stream_state.stream

type request_error =
  | Admission_rejected of { limit : int }
  | Connection_closed
  | Request_failed of string

type opened_request = {
  stream : stream;
  request_body : H2.Body.Writer.t;
}

type h2_request =
  H2.Client_connection.t ->
  ?trailers_handler:(H2.Headers.t -> unit) ->
  H2.Request.t ->
  error_handler:(H2.Client_connection.error -> unit) ->
  response_handler:(H2.Response.t -> H2.Body.Reader.t -> unit) ->
  H2.Body.Writer.t

type t = {
  client : H2.Client_connection.t;
  streams : Stream_state.t;
  request_bodies : (int, H2.Body.Writer.t) Hashtbl.t;
  response_bodies : (int, H2.Body.Reader.t) Hashtbl.t;
  security : Security.t option;
  mutable closed : bool;
}

let create ?(max_concurrent = 128) ?config ?push_handler
    ?security ?(error_handler = fun _ -> ()) () =
  let holder = ref None in
  let client =
    H2.Client_connection.create ?config ?push_handler
      ~error_handler:(fun error ->
        (match !holder with Some t -> t.closed <- true | None -> ());
        error_handler error)
      ()
  in
  let t =
    {
      client;
      streams = Stream_state.create ~max_concurrent;
      request_bodies = Hashtbl.create max_concurrent;
      response_bodies = Hashtbl.create max_concurrent;
      security;
      closed = false;
    }
  in
  holder := Some t;
  t

let client_connection t = t.client
let stats t = Stream_state.stats t.streams
let complete_security_stream t stream_id =
  Option.iter (fun security -> Security.complete_stream security stream_id) t.security

let mark_complete t stream =
  Stream_state.mark_complete t.streams stream;
  complete_security_stream t (Stream_state.id stream)

let mark_remote_reset t stream_id =
  Stream_state.mark_remote_reset t.streams stream_id;
  complete_security_stream t stream_id

let close_request_body body =
  try
    if not (H2.Body.Writer.is_closed body) then H2.Body.Writer.close body
  with _ -> ()

let release t stream =
  let stream_id = Stream_state.id stream in
  let decision = Stream_state.release t.streams stream in
  (match Hashtbl.find_opt t.request_bodies stream_id with
  | Some body ->
      close_request_body body;
      Hashtbl.remove t.request_bodies stream_id
  | None -> ());
  (match Hashtbl.find_opt t.response_bodies stream_id with
  | Some body ->
      if not (H2.Body.Reader.is_closed body) then H2.Body.Reader.close body;
      Hashtbl.remove t.response_bodies stream_id
  | None -> ());
  complete_security_stream t stream_id;
  decision

let shutdown t =
  if not t.closed then (
    t.closed <- true;
    H2.Client_connection.shutdown t.client;
    Stream_state.close t.streams;
    Hashtbl.iter (fun _ body -> close_request_body body) t.request_bodies;
    Hashtbl.clear t.request_bodies;
    Hashtbl.clear t.response_bodies)

let request_with_h2_request h2_request t ~tag ?trailers_handler request
    ~error_handler ~response_handler =
  if t.closed || H2.Client_connection.is_closed t.client then
    Error Connection_closed
  else
    match Stream_state.open_stream t.streams ~tag with
    | Error () ->
        let stats = Stream_state.stats t.streams in
        Error (Admission_rejected { limit = stats.max_concurrent })
    | Ok stream ->
        let stream_id = Stream_state.id stream in
        try
          let request_body =
            h2_request t.client ?trailers_handler request
              ~error_handler:(fun error ->
                Stream_state.mark_remote_reset t.streams stream_id;
                error_handler stream error)
              ~response_handler:(fun response body ->
                Hashtbl.replace t.response_bodies stream_id body;
                response_handler stream response body)
          in
          Hashtbl.replace t.request_bodies stream_id request_body;
          Ok { stream; request_body }
        with exn ->
          ignore (release t stream);
          Error (Request_failed (Printexc.to_string exn))

let request =
  request_with_h2_request (fun client ?trailers_handler request ~error_handler
                              ~response_handler ->
      H2.Client_connection.request client request ?trailers_handler ~error_handler
        ~response_handler)

type client_reader = {
  client : H2.Client_connection.t;
  security : Security.t;
  filter : Informational_filter.t;
  buffer : Bigstringaf.t;
  mutable filtered : string;
  mutable filtered_off : int;
  mutable off : int;
  mutable len : int;
  mutable eof : bool;
}

type read_result =
  | Read of int
  | Eof of int
  | Close
  | Security_error of Error.kind

type body_event =
  | Body_chunk of bytes
  | Body_eof

let create_client_reader ?(buffer_size = 64 * 1024) ?security ?security_config
    client =
  if buffer_size <= 0 then
    invalid_arg "Eta_http.H2.Multiplexer.create_client_reader: buffer_size must be > 0";
  let security =
    match (security, security_config) with
    | Some _, Some _ ->
        invalid_arg
          "Eta_http.H2.Multiplexer.create_client_reader: pass either security or security_config, not both"
    | Some security, None -> security
    | None, _ -> Security.create ?config:security_config ()
  in
  let buffer = Bigstringaf.create buffer_size in
  {
    client;
    security;
    filter = Informational_filter.create ();
    buffer;
    filtered = "";
    filtered_off = 0;
    off = 0;
    len = 0;
    eof = false;
  }

let client reader = reader.client
let capacity reader = Bigstringaf.length reader.buffer

let compact reader =
  if reader.off > 0 && reader.len > 0 then (
    Bigstringaf.blit reader.buffer ~src_off:reader.off reader.buffer ~dst_off:0
      ~len:reader.len;
    reader.off <- 0)
  else if reader.len = 0 then reader.off <- 0

let feed_pending reader =
  let consumed =
    H2.Client_connection.read reader.client reader.buffer ~off:reader.off
      ~len:reader.len
  in
  reader.off <- reader.off + consumed;
  reader.len <- reader.len - consumed;
  consumed

let feed_eof reader =
  if reader.eof then Eof 0
  else (
    reader.eof <- true;
    let consumed =
      H2.Client_connection.read_eof reader.client reader.buffer ~off:reader.off
        ~len:reader.len
    in
    reader.off <- reader.off + consumed;
    reader.len <- reader.len - consumed;
    Eof consumed)

let copy_filtered reader =
  let available = String.length reader.filtered - reader.filtered_off in
  if available <= 0 then 0
  else
    let copied = min available (capacity reader - reader.len) in
    Bigstringaf.blit_from_string reader.filtered ~src_off:reader.filtered_off
      reader.buffer ~dst_off:reader.len ~len:copied;
    reader.filtered_off <- reader.filtered_off + copied;
    reader.len <- reader.len + copied;
    if reader.filtered_off >= String.length reader.filtered then (
      reader.filtered <- "";
      reader.filtered_off <- 0);
    copied

let read_more ~flow reader =
  compact reader;
  match copy_filtered reader with
  | copied when copied > 0 -> `Read_more copied
  | _ when reader.len >= capacity reader -> `Buffer_full
  | _ ->
      let free_space = capacity reader - reader.len in
      let view = Cstruct.of_bigarray reader.buffer ~off:reader.len ~len:free_space in
      try
        let read = Eio.Flow.single_read flow view in
        (match Security.observe reader.security reader.buffer ~off:reader.len ~len:read with
        | Some error -> `Security_error error
        | None ->
            if Informational_filter.is_passthrough reader.filter then (
              reader.len <- reader.len + read;
              `Read_more read)
            else (
              let raw = Bigstringaf.substring reader.buffer ~off:reader.len ~len:read in
              match Informational_filter.feed reader.filter raw ~off:0 ~len:read with
              | Error error -> `Security_error error
              | Ok () ->
                  reader.filtered <- Informational_filter.take reader.filter;
                  reader.filtered_off <- 0;
                  let copied = copy_filtered reader in
                  if copied = 0
                     && Informational_filter.buffered_bytes reader.filter
                        >= capacity reader
                  then `Buffer_full
                  else `Read_more copied))
      with End_of_file -> `Eof

let buffer_exhausted reader =
  Security_error
    (Error.Connection_protocol_violation
       {
         kind = "h2_read_buffer_exhausted";
         message =
           Printf.sprintf
             "h2 read buffer of %d bytes filled without parser progress"
             (capacity reader);
       })

let has_filtered reader =
  String.length reader.filtered > reader.filtered_off

let rec read_client_once ~flow reader =
  if reader.len > 0 then
    match feed_pending reader with
    | consumed when consumed > 0 -> Read consumed
    | _ -> read_client_next ~flow reader
  else if has_filtered reader then
    match copy_filtered reader with
    | copied when copied > 0 -> read_client_once ~flow reader
    | _ -> read_client_next ~flow reader
  else read_client_next ~flow reader

and read_client_next ~flow reader =
  match H2.Client_connection.next_read_operation reader.client with
  | `Close -> Close
  | `Read -> (
      if reader.eof then Eof 0
      else
        match read_more ~flow reader with
        | `Read_more _ -> read_client_once ~flow reader
        | `Security_error error -> Security_error error
        | `Eof -> feed_eof reader
        | `Buffer_full -> buffer_exhausted reader)

let body_stream ?(poll_error = fun () -> None) ?(on_eof = fun () -> ())
    ?(on_release = fun _ -> Eta.Effect.unit) ~closed_error ~pump t stream body =
  let events = Queue.create () in
  let scheduled = ref false in
  let eof = ref false in
  let push_event event = Queue.push event events in
  let pop_event () =
    if Queue.is_empty events then None else Some (Queue.take events)
  in
  let finish_eof () =
    if not !eof then (
      eof := true;
      on_eof ();
      mark_complete t stream)
  in
  let schedule_read () =
    if (not !scheduled) && (not !eof) && not (H2.Body.Reader.is_closed body) then (
      scheduled := true;
      H2.Body.Reader.schedule_read body
        ~on_eof:(fun () ->
          scheduled := false;
          finish_eof ();
          push_event Body_eof)
        ~on_read:(fun bs ~off ~len ->
          scheduled := false;
          let chunk = Bytes.create len in
          Bigstringaf.blit_to_bytes bs ~src_off:off chunk ~dst_off:0 ~len;
          push_event (Body_chunk chunk)))
  in
  let release_body () =
    let decision = release t stream in
    on_release decision
  in
  let emit_event = function
    | Body_chunk chunk -> Eta.Effect.pure (Stream.Chunk chunk)
    | Body_eof -> Eta.Effect.pure Stream.End
  in
  let closed_or_error () =
    match poll_error () with
    | Some error -> Eta.Effect.fail error
    | None when !eof -> Eta.Effect.pure Stream.End
    | None when H2.Body.Reader.is_closed body ->
        finish_eof ();
        Eta.Effect.pure Stream.End
    | None -> Eta.Effect.fail closed_error
  in
  let rec read_next () =
    match pop_event () with
    | Some event -> emit_event event
    | None -> (
        match poll_error () with
        | Some error -> Eta.Effect.fail error
        | None when !eof -> Eta.Effect.pure Stream.End
        | None when H2.Body.Reader.is_closed body ->
            finish_eof ();
            Eta.Effect.pure Stream.End
        | None -> read_after_schedule ())
  and read_after_schedule () =
    schedule_read ();
    match pop_event () with
    | Some event -> emit_event event
    | None ->
        pump ()
        |> Eta.Effect.bind (fun result ->
               match pop_event () with
               | Some event -> emit_event event
               | None -> (
                   match result with
                   | Read _ -> read_next ()
                   | Security_error _ | Eof _ | Close -> closed_or_error ()))
  in
  schedule_read ();
  Stream.of_reader ~release:release_body read_next

type body_async_state = {
  mutable scheduled : bool;
  mutable eof : bool;
}

let body_stream_async ?(poll_error = fun () -> None) ?(on_eof = fun () -> ())
    ?(on_release = fun _ -> Eta.Effect.unit) ~closed_error t stream body =
  let mutex = Eio.Mutex.create () in
  let condition = Eio.Condition.create () in
  let events = Queue.create () in
  let state = { scheduled = false; eof = false } in
  let notify () = Eio.Condition.broadcast condition in
  let with_lock f =
    Eio.Mutex.lock mutex;
    Fun.protect ~finally:(fun () -> Eio.Mutex.unlock mutex) f
  in
  let finish_eof () =
    let first =
      with_lock (fun () ->
          if state.eof then false
          else (
            state.eof <- true;
            Queue.push Body_eof events;
            true))
    in
    if first then (
      on_eof ();
      mark_complete t stream;
      notify ())
  in
  let push_chunk bs ~off ~len =
    let chunk = Bytes.create len in
    Bigstringaf.blit_to_bytes bs ~src_off:off chunk ~dst_off:0 ~len;
    with_lock (fun () ->
        state.scheduled <- false;
        Queue.push (Body_chunk chunk) events);
    notify ()
  in
  let rec schedule_read () =
    let keep_scheduling = ref true in
    while !keep_scheduling do
      keep_scheduling := false;
      let should_schedule =
        with_lock (fun () ->
            (not state.scheduled)
            && (not state.eof)
            && not (H2.Body.Reader.is_closed body))
      in
      if should_schedule then (
        let delivered_sync = ref false in
        with_lock (fun () -> state.scheduled <- true);
        H2.Body.Reader.schedule_read body
          ~on_eof:(fun () ->
            with_lock (fun () -> state.scheduled <- false);
            finish_eof ())
          ~on_read:(fun bs ~off ~len ->
            delivered_sync := true;
            push_chunk bs ~off ~len);
        if !delivered_sync then keep_scheduling := true)
    done
  in
  let release_body () =
    let decision = release t stream in
    notify ();
    on_release decision
  in
  let emit_event = function
    | Body_chunk chunk -> Eta.Effect.pure (Stream.Chunk chunk)
    | Body_eof -> Eta.Effect.pure Stream.End
  in
  let next_locked () =
    match poll_error () with
    | Some error -> Some (`Error error)
    | None when not (Queue.is_empty events) -> Some (`Event (Queue.take events))
    | None when state.eof -> Some (`Event Body_eof)
    | None when H2.Body.Reader.is_closed body -> Some `Closed
    | None -> None
  in
  let await_event () =
    match with_lock next_locked with
    | None ->
        schedule_read ();
        with_lock (fun () ->
            let rec loop () =
              match next_locked () with
              | None ->
                  Eio.Condition.await condition mutex;
                  loop ()
              | Some result -> result
            in
            loop ())
    | Some result -> result
  in
  let read_next () =
    Eta.Effect.sync await_event
    |> Eta.Effect.bind (function
         | `Event event -> emit_event event
         | `Error error -> Eta.Effect.fail error
         | `Closed ->
             finish_eof ();
             Eta.Effect.pure Stream.End)
  in
  schedule_read ();
  (Stream.of_reader ~release:release_body read_next, notify)
