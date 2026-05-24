(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

module Stream_state = Stream_state
module Security = Security

type stream = Stream_state.stream

type request_error =
  | Admission_rejected
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
  response_bodies : (int, H2.Body.Reader.t) Hashtbl.t;
  mutable closed : bool;
}

let create ?(max_concurrent = 128) ?config ?push_handler
    ?(error_handler = fun _ -> ()) () =
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
      response_bodies = Hashtbl.create max_concurrent;
      closed = false;
    }
  in
  holder := Some t;
  t

let client_connection t = t.client
let stats t = Stream_state.stats t.streams
let mark_complete t stream = Stream_state.mark_complete t.streams stream
let mark_remote_reset t stream_id = Stream_state.mark_remote_reset t.streams stream_id

let release t stream =
  let stream_id = Stream_state.id stream in
  (match Hashtbl.find_opt t.response_bodies stream_id with
  | Some body ->
      if not (H2.Body.Reader.is_closed body) then H2.Body.Reader.close body;
      Hashtbl.remove t.response_bodies stream_id
  | None -> ());
  Stream_state.release t.streams stream

let shutdown t =
  if not t.closed then (
    t.closed <- true;
    H2.Client_connection.shutdown t.client;
    Stream_state.close t.streams;
    Hashtbl.clear t.response_bodies)

let request_with_h2_request h2_request t ~tag ?trailers_handler request
    ~error_handler ~response_handler =
  if t.closed || H2.Client_connection.is_closed t.client then
    Error Connection_closed
  else
    match Stream_state.open_stream t.streams ~tag with
    | Error () -> Error Admission_rejected
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
          Ok { stream; request_body }
        with exn ->
          ignore (release t stream);
          Error (Request_failed (Printexc.to_string exn))

let request =
  request_with_h2_request (fun client ?trailers_handler request ~error_handler
                              ~response_handler ->
      H2.Client_connection.request client request ?trailers_handler ~error_handler
        ~response_handler)

module For_test = struct
  let request_with_h2_request = request_with_h2_request
end

type client_reader = {
  client : H2.Client_connection.t;
  security : Security.t;
  buffer : Bigstringaf.t;
  mutable off : int;
  mutable len : int;
  mutable eof : bool;
}

type read_result =
  | Read of int
  | Eof of int
  | Close
  | Security_error of Eta_http_error.Error.kind

type body_event =
  | Body_chunk of bytes
  | Body_eof

let create_client_reader ?(buffer_size = 64 * 1024) ?security_config client =
  if buffer_size <= 0 then
    invalid_arg "Eta_http.H2.Multiplexer.create_client_reader: buffer_size must be > 0";
  let buffer = Bigstringaf.create buffer_size in
  {
    client;
    security = Security.create ?config:security_config ();
    buffer;
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

let read_more ~flow reader =
  compact reader;
  if reader.len >= capacity reader then `Buffer_full
  else
    let view =
      Cstruct.of_bigarray ~off:reader.len
        ~len:(capacity reader - reader.len)
        reader.buffer
    in
    try
      let read = Eio.Flow.single_read flow view in
      (match Security.observe reader.security reader.buffer ~off:reader.len ~len:read with
      | Some error -> `Security_error error
      | None ->
          reader.len <- reader.len + read;
          `Read_more read)
    with End_of_file -> `Eof

let buffer_exhausted reader =
  Security_error
    (Eta_http_error.Error.Connection_protocol_violation
       {
         kind = "h2_read_buffer_exhausted";
         message =
           Printf.sprintf
             "h2 read buffer of %d bytes filled without parser progress"
             (capacity reader);
       })

let rec read_client_once ~flow reader =
  match H2.Client_connection.next_read_operation reader.client with
  | `Close -> Close
  | `Read ->
      if reader.len > 0 then
        match feed_pending reader with
        | consumed when consumed > 0 -> Read consumed
        | _ -> (
            match read_more ~flow reader with
            | `Read_more _ -> read_client_once ~flow reader
            | `Security_error error -> Security_error error
            | `Eof -> feed_eof reader
            | `Buffer_full -> buffer_exhausted reader)
      else if reader.eof then Eof 0
      else
        match read_more ~flow reader with
        | `Read_more _ -> read_client_once ~flow reader
        | `Security_error error -> Security_error error
        | `Eof -> feed_eof reader
        | `Buffer_full -> buffer_exhausted reader

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
          push_event (Body_chunk (Bytes.of_string (Bigstringaf.substring bs ~off ~len)))))
  in
  let release_body () =
    let decision = release t stream in
    on_release decision
  in
  let emit_event = function
    | Body_chunk chunk -> Eta.Effect.pure (Eta_http_body.Stream.Chunk chunk)
    | Body_eof -> Eta.Effect.pure Eta_http_body.Stream.End
  in
  let closed_or_error () =
    match poll_error () with
    | Some error -> Eta.Effect.fail error
    | None when !eof -> Eta.Effect.pure Eta_http_body.Stream.End
    | None when H2.Body.Reader.is_closed body ->
        finish_eof ();
        Eta.Effect.pure Eta_http_body.Stream.End
    | None -> Eta.Effect.fail closed_error
  in
  let rec read_next () =
    match pop_event () with
    | Some event -> emit_event event
    | None -> (
        match poll_error () with
        | Some error -> Eta.Effect.fail error
        | None when !eof -> Eta.Effect.pure Eta_http_body.Stream.End
        | None when H2.Body.Reader.is_closed body ->
            finish_eof ();
            Eta.Effect.pure Eta_http_body.Stream.End
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
  Eta_http_body.Stream.of_reader ~release:release_body read_next
