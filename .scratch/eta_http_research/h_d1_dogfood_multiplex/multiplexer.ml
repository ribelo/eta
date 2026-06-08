open Eta
open Frame

type stats = Stream_state.stats

type release_error = [ `Closed | `Writer_full ]

type response_stream = {
  stream_id : int;
  tag : int;
  release : unit -> (unit, release_error) Effect.t;
}

type t = {
  conn : Fake_multiplex_connection.t;
  outbound : Frame.t Channel.t;
  streams : Stream_state.t;
}

let create ?(max_streams = 128) ?(outbound_capacity = 256)
    ?(window_chunks = 8) conn =
  {
    conn;
    outbound = Channel.create ~capacity:outbound_capacity ();
    streams = Stream_state.create ~max_concurrent:max_streams ~window_chunks;
  }

let stats t = Stream_state.stats t.streams

let ignore_try_send result =
  match result with
  | `Sent | `Full | `Closed -> Effect.unit

let enqueue t frame =
  Channel.try_send t.outbound frame
  |> Effect.bind (function
       | `Sent -> Effect.unit
       | `Full -> Effect.fail `Writer_full
       | `Closed -> Effect.fail `Closed)

let enqueue_best_effort t frame =
  Channel.try_send t.outbound frame |> Effect.bind ignore_try_send

let release_stream t stream =
  let should_rst = Stream_state.release t.streams stream in
  if should_rst then
    enqueue_best_effort t
      (Rst_stream { stream_id = stream.Stream_state.id; error = Cancel })
  else Effect.unit

let release_stream_once t stream =
  let released = ref false in
  fun () ->
    if !released then Effect.unit
    else (
      released := true;
      release_stream t stream)

let with_stream t ~tag body =
  let acquire =
    Effect.sync (fun () -> Stream_state.open_stream t.streams ~tag)
    |> Effect.bind (function
         | `Stream stream -> Effect.pure stream
         | `Rejected -> Effect.fail `Admission_limited)
  in
  Effect.scoped
    (Effect.acquire_release ~acquire ~release:(release_stream t)
    |> Effect.bind body)

let with_open_stream t ~tag body =
  let acquire =
    Effect.sync (fun () -> Stream_state.open_stream t.streams ~tag)
    |> Effect.bind (function
         | `Stream stream -> Effect.pure stream
         | `Rejected -> Effect.fail `Admission_limited)
  in
  let armed = ref true in
  let release stream =
    if !armed then release_stream t stream else Effect.unit
  in
  Effect.scoped
    (Effect.acquire_release ~acquire ~release
    |> Effect.bind (fun stream ->
           let disarm () = armed := false in
           body ~disarm stream))

let drain_window stream chunks =
  let rec loop remaining =
    if remaining <= 0 then Effect.unit
    else
      Channel.try_recv stream.Stream_state.window_used
      |> Effect.bind (function
           | `Item () -> loop (remaining - 1)
           | `Empty | `Closed -> Effect.unit)
  in
  loop chunks

let deliver_to_stream t frame =
  match Frame.stream_id frame with
  | None -> Effect.unit
  | Some stream_id -> (
      (match frame with
      | Frame.Rst_stream _ ->
          Effect.sync (fun () -> Stream_state.mark_remote_reset t.streams stream_id)
      | Window_update { bytes; _ } -> (
          match Stream_state.find t.streams stream_id with
          | None -> Effect.unit
          | Some stream ->
              drain_window stream (max 1 (bytes / 1024)))
      | _ -> Effect.unit)
      |> Effect.bind (fun () ->
             match Stream_state.find t.streams stream_id with
             | None -> Effect.unit
             | Some stream ->
                 Channel.try_send stream.Stream_state.inbound frame
                 |> Effect.bind ignore_try_send))

let rec read_loop t =
  Fake_multiplex_connection.read_frame t.conn
  |> Effect.bind (fun frame ->
         deliver_to_stream t frame |> Effect.bind (fun () -> read_loop t))
  |> Effect.catch (function
       | `Socket_closed -> Effect.unit
       | err -> Effect.fail err)

let send_body t stream ~tag ~chunks =
  let rec loop n =
    if n <= 0 then Effect.unit
    else
      Channel.send stream.Stream_state.window_used ()
      |> Effect.bind (fun () ->
             enqueue t
               (Data
                  {
                    stream_id = stream.Stream_state.id;
                    tag;
                    bytes = 1024;
                    end_stream = n = 1;
                  })
             |> Effect.bind (fun () -> loop (n - 1)))
  in
  loop chunks

let rec await_response t stream =
  Channel.recv stream.Stream_state.inbound
  |> Effect.bind (function
       | Headers { end_stream = true; _ } ->
           Effect.sync (fun () -> Stream_state.mark_complete t.streams stream)
           |> Effect.map (fun () -> `Response)
       | Rst_stream _ -> Effect.fail `Stream_reset
       | Window_update _ | Headers _ | Data _ | Ping _ -> await_response t stream)

let request ?(body_chunks = 0) t ~tag =
  with_stream t ~tag @@ fun stream ->
  enqueue t
    (Headers
       {
         stream_id = stream.Stream_state.id;
         tag;
         end_stream = body_chunks = 0;
       })
  |> Effect.bind (fun () ->
         (if body_chunks = 0 then Effect.unit else send_body t stream ~tag ~chunks:body_chunks)
         |> Effect.bind (fun () -> await_response t stream))

let request_open ?(body_chunks = 0) t ~tag =
  with_open_stream t ~tag @@ fun ~disarm stream ->
  enqueue t
    (Headers
       {
         stream_id = stream.Stream_state.id;
         tag;
         end_stream = body_chunks = 0;
       })
  |> Effect.bind (fun () ->
         (if body_chunks = 0 then Effect.unit
          else send_body t stream ~tag ~chunks:body_chunks)
         |> Effect.bind (fun () -> await_response t stream))
  |> Effect.map (fun _ ->
         disarm ();
         {
           stream_id = stream.Stream_state.id;
           tag;
           release = release_stream_once t stream;
         })

let ping t n = enqueue t (Ping n)

let shutdown t =
  Effect.sync @@ fun () ->
  Channel.close t.outbound;
  Stream_state.close_all t.streams

let with_connection ?max_streams ?outbound_capacity ?window_chunks conn body =
  let t = create ?max_streams ?outbound_capacity ?window_chunks conn in
  Supervisor.scoped
    {
      run =
        (fun supervisor ->
          let open Supervisor.Scope in
          let* _writer =
            start supervisor (lift (Writer_fiber.run conn t.outbound))
          in
          let* _reader = start supervisor (lift (read_loop t)) in
          lift
            (Effect.acquire_release ~acquire:(Effect.pure t) ~release:shutdown
            |> Effect.bind body));
    }
