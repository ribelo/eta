open Eta

module Api = Request_api

type request_job = {
  req : Api.Request.t;
  reply : (Api.Response.t, Api.error) result Channel.t;
}

type job = Request of request_job | Stats of Api.Stats.t Channel.t

type t = {
  server : Fixture_server.t;
  conn : Fake_multiplex_connection.t;
  jobs : job Channel.t;
  mutex : Eio.Mutex.t;
  max_streams : int;
  mutable next_tag : int;
  mutable released : int;
  mutable last_raw : Multiplexer.stats option;
}

let with_lock mutex f =
  Eio.Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock mutex) f

let send_best_effort ch value =
  Channel.try_send ch value
  |> Effect.map (function `Sent | `Full | `Closed -> ())

let next_tag t =
  Effect.sync @@ fun () ->
  with_lock t.mutex @@ fun () ->
  let tag = t.next_tag in
  t.next_tag <- t.next_tag + 1;
  tag

let update_raw t mux =
  Effect.sync @@ fun () ->
  with_lock t.mutex @@ fun () -> t.last_raw <- Some (Multiplexer.stats mux)

let mark_released t mux =
  Effect.sync (fun () ->
      with_lock t.mutex @@ fun () -> t.released <- t.released + 1)
  |> Effect.bind (fun () -> update_raw t mux)

let released t = with_lock t.mutex @@ fun () -> t.released

let raw_or_empty t : Multiplexer.stats =
  with_lock t.mutex @@ fun () ->
  match t.last_raw with
  | Some raw -> raw
  | None ->
      ({
        active = 0;
        cancelled = 0;
        live = 0;
        opened = 0;
        completed = 0;
        remote_resets = 0;
        local_resets = 0;
        admission_rejected = 0;
        max_inflight = 0;
      } : Multiplexer.stats)

let stats_from_raw t (raw : Multiplexer.stats) =
  {
    Api.Stats.protocol = H2;
    active = raw.active;
    idle = max 0 (t.max_streams - raw.active);
    capacity = t.max_streams;
    opened = raw.opened;
    released = released t;
    raw =
      [
        Printf.sprintf
          "h2_streams active=%d live=%d opened=%d completed=%d local_resets=%d"
          raw.active raw.live raw.opened raw.completed raw.local_resets;
        Printf.sprintf
          "h2_admission rejected=%d max_inflight=%d remote_resets=%d"
          raw.admission_rejected raw.max_inflight raw.remote_resets;
        Printf.sprintf "h2_server opened=%d closed=%d"
          (Fixture_server.stats t.server).h2_opened
          (Fixture_server.stats t.server).h2_closed;
      ];
  }

let stats_latest t = Effect.sync (fun () -> stats_from_raw t (raw_or_empty t))

let map_request_error t req = function
  | `Admission_limited ->
      Api.Private.error H2 req
        (Error.Stream_admission_rejected { limit = t.max_streams })
  | `Stream_reset ->
      Api.Private.error H2 req
        (Error.Connection_closed { during = Error.Http_response })
  | `Closed | `Socket_closed | `Writer_full ->
      Api.Private.error H2 req
        (Error.Connection_closed { during = Error.Http_request })

let release_body t mux handle =
  handle.Multiplexer.release ()
  |> Effect.catch (function `Closed | `Writer_full -> Effect.unit)
  |> Effect.bind (fun () -> mark_released t mux)

let make_response t mux req handle =
  let plan = Api.Private.response_plan req in
  let body =
    Api.Private.make_stream ?delay_per_chunk:plan.delay_per_chunk
      ~release:(fun () -> release_body t mux handle)
      plan.chunks
  in
  {
    Api.Response.status = plan.status;
    headers = plan.headers;
    body;
    trailers = (fun () -> Effect.pure plan.trailers);
  }

let handle_request t mux job =
  next_tag t
  |> Effect.bind (fun tag ->
         Multiplexer.request_open ~body_chunks:(Api.Request.body_chunks job.req) mux
           ~tag)
  |> Effect.bind (fun handle ->
         update_raw t mux
         |> Effect.bind (fun () ->
                send_best_effort job.reply
                  (Ok (make_response t mux job.req handle))))
  |> Effect.catch (fun err ->
         send_best_effort job.reply (Error (map_request_error t job.req err)))

let handle_stats t mux reply =
  update_raw t mux
  |> Effect.bind (fun () -> stats_latest t)
  |> Effect.bind (send_best_effort reply)

let rec loop t mux =
  Channel.recv t.jobs
  |> Effect.map Option.some
  |> Effect.catch (function `Closed -> Effect.pure None)
  |> Effect.bind (function
       | None -> Effect.unit
       | Some (Request job) ->
           handle_request t mux job |> Effect.bind (fun () -> loop t mux)
       | Some (Stats reply) ->
           handle_stats t mux reply |> Effect.bind (fun () -> loop t mux))

let serve t =
  Effect.scoped
    (Effect.acquire_release ~acquire:Effect.unit
       ~release:(fun () -> Effect.sync (fun () -> Fixture_server.close_h2 t.server t.conn))
    |> Effect.bind (fun () ->
           Multiplexer.with_connection ~max_streams:t.max_streams t.conn
             (loop t)))

let request t req =
  let reply = Channel.create ~capacity:1 () in
  let closed =
    Api.Private.error H2 req
      (Error.Connection_closed { during = Error.Http_request })
  in
  Channel.send t.jobs (Request { req; reply })
  |> Effect.catch (function `Closed -> Effect.fail closed)
  |> Effect.bind (fun () ->
         Channel.recv reply
         |> Effect.catch (function `Closed -> Effect.pure (Error closed)))
  |> Effect.bind (function
       | Ok response -> Effect.pure response
       | Error err -> Effect.fail err)

let stats t =
  let reply = Channel.create ~capacity:1 () in
  Channel.try_send t.jobs (Stats reply)
  |> Effect.bind (function
       | `Sent -> Channel.recv reply
       | `Full | `Closed -> stats_latest t)
  |> Effect.catch (function `Closed -> stats_latest t)

let shutdown t =
  Effect.sync (fun () -> Channel.close t.jobs)

let create ?(max_streams = 8) () =
  let server = Fixture_server.create Pending_connection.H2 in
  let conn = Fixture_server.open_h2 server in
  let state =
    {
      server;
      conn;
      jobs = Channel.create ~capacity:64 ();
      mutex = Eio.Mutex.create ();
      max_streams;
      next_tag = 1;
      released = 0;
      last_raw = None;
    }
  in
  let guarded =
    serve state
    |> Effect.catch (function
         | `Admission_limited | `Closed | `Socket_closed | `Stream_reset
         | `Writer_full ->
             Effect.unit)
  in
  Effect.Private.daemon guarded
  |> Effect.map (fun () ->
         Api.Private.make_client ~protocol:H2 ~request:(request state)
           ~stats:(fun () -> stats state)
           ~shutdown:(fun () -> shutdown state))
