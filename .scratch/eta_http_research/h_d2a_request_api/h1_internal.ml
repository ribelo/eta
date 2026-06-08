open Eta

module Api = Request_api

type release_ack = unit Channel.t

type t = {
  server : Fixture_server.t;
  pool : (Fixture_server.h1_conn, [ `Pool_shutdown | `Pool_shutdown_timeout ]) Pool.t;
  mutex : Eio.Mutex.t;
  mutable released : int;
}

let with_lock mutex f =
  Eio.Mutex.lock mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock mutex) f

let mark_released t =
  Effect.sync (fun () -> with_lock t.mutex @@ fun () -> t.released <- t.released + 1)

let released t = with_lock t.mutex @@ fun () -> t.released

let send_best_effort ch value =
  Channel.try_send ch value
  |> Effect.map (function `Sent | `Full | `Closed -> ())

let release_body release_ch =
  let ack = Channel.create ~capacity:1 () in
  Channel.try_send release_ch ack
  |> Effect.bind (function
       | `Sent ->
           Channel.recv ack
           |> Effect.catch (function `Closed -> Effect.unit)
       | `Full | `Closed -> Effect.unit)

let make_response req release_ch =
  let plan = Api.Private.response_plan req in
  let body =
    Api.Private.make_stream ?delay_per_chunk:plan.delay_per_chunk
      ~release:(fun () -> release_body release_ch)
      plan.chunks
  in
  {
    Api.Response.status = plan.status;
    headers = plan.headers;
    body;
    trailers = (fun () -> Effect.pure plan.trailers);
  }

let owner t req response_ch release_ch =
  let ack = ref None in
  let report_error err = send_best_effort response_ch (Error err) in
  let hold_resource =
    Pool.with_resource t.pool (fun conn ->
        Effect.sync (fun () -> Fixture_server.record_h1_request t.server conn)
        |> Effect.bind (fun () ->
               let response = make_response req release_ch in
               Channel.try_send response_ch (Ok response))
        |> Effect.bind (function
             | `Sent ->
                 Channel.recv release_ch
                 |> Effect.map (fun release_ack -> ack := Some release_ack)
                 |> Effect.catch (function `Closed -> Effect.unit)
             | `Full | `Closed -> Effect.unit))
  in
  hold_resource
  |> Effect.bind (fun () ->
         mark_released t
         |> Effect.bind (fun () ->
                match !ack with
                | None -> Effect.unit
                | Some release_ack -> send_best_effort release_ack ()))
  |> Effect.catch (function
       | `Pool_shutdown ->
           report_error
             (Api.Private.error H1 req Error.Pool_shutdown)
       | `Pool_shutdown_timeout -> Effect.unit
       )

let request t req =
  let response_ch = Channel.create ~capacity:1 () in
  let release_ch = Channel.create ~capacity:1 () in
  let closed =
    Api.Private.error H1 req
      (Error.Connection_closed { during = Error.Http_request })
  in
  Effect.Private.daemon (owner t req response_ch release_ch)
  |> Effect.bind (fun () ->
         Channel.recv response_ch
         |> Effect.catch (function `Closed -> Effect.pure (Error closed)))
  |> Effect.bind (function
       | Ok response -> Effect.pure response
       | Error err -> Effect.fail err)

let stats t =
  Effect.sync @@ fun () ->
  let pool = Pool.stats t.pool in
  {
    Api.Stats.protocol = H1;
    active = pool.active;
    idle = pool.idle;
    capacity = pool.max_size;
    opened = pool.opened;
    released = released t;
    raw =
      [
        Printf.sprintf
          "h1_pool active=%d idle=%d waiting=%d opened=%d closed=%d"
          pool.active pool.idle pool.waiting pool.opened pool.closed;
        Printf.sprintf "h1_server requests=%d opened=%d closed=%d"
          (Fixture_server.stats t.server).h1_requests
          (Fixture_server.stats t.server).h1_opened
          (Fixture_server.stats t.server).h1_closed;
      ];
  }

let shutdown t =
  Pool.shutdown t.pool
  |> Effect.catch (function
       | `Pool_shutdown | `Pool_shutdown_timeout -> Effect.unit)

let create () =
  let server = Fixture_server.create Pending_connection.H1 in
  Pool.create ~name:"h-d2a-h1" ~kind:"http/1.1" ~max_size:2
    ~acquire:(Fixture_server.acquire_h1 server)
    ~release:(Fixture_server.close_h1 server) ()
  |> Effect.map (fun pool ->
         let state = { server; pool; mutex = Eio.Mutex.create (); released = 0 } in
         Api.Private.make_client ~protocol:H1 ~request:(request state)
           ~stats:(fun () -> stats state)
           ~shutdown:(fun () -> shutdown state))
  |> Effect.catch (function
       | `Pool_shutdown | `Pool_shutdown_timeout ->
           Effect.fail
             (Error.make ~protocol:Error.H1 ~method_:"CLIENT" ~uri:"eta://h1"
                Error.Pool_shutdown))
