open Eta

type response = [ `H1 of int | `H2 of int ]

type h2_reply =
  [ `Ok
  | `Admission_limited
  | `Closed
  | `Socket_closed
  | `Stream_reset
  | `Writer_full ]

type error =
  [ `Admission_limited
  | `Closed
  | `Connection_cancelled
  | `Pool_shutdown
  | `Pool_shutdown_timeout
  | `Socket_closed
  | `Stream_reset
  | `Writer_full ]

type h2_job = { tag : int; reply : h2_reply Channel.t }

type h2_cell = {
  id : int;
  conn : Fake_multiplex_connection.t;
  jobs : h2_job Channel.t;
  mutable closed : bool;
}

type route =
  | Pending of Pending_connection.t
  | H1_pool
  | H2_cell of h2_cell

type stats = {
  h1_pool : Pool.stats;
  h2_cells : int;
  h2_requests : int;
  redundant_cancelled : int;
  server : Fixture_server.stats;
}

type t = {
  server : Fixture_server.t;
  mutex : Eio.Mutex.t;
  routes : (string, route) Hashtbl.t;
  h1_pool : (Fixture_server.h1_conn, error) Pool.t;
  mutable next_h2_id : int;
  mutable h2_cells : int;
  mutable h2_requests : int;
  mutable redundant_cancelled : int;
}

let key ~host ~port = host ^ ":" ^ string_of_int port

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let create server =
  Pool.create ~name:"h-d5-h1" ~kind:"http/1.1" ~max_size:16
    ~acquire:(Fixture_server.acquire_h1 server)
    ~release:(Fixture_server.close_h1 server) ()
  |> Effect.map (fun h1_pool ->
         {
           server;
           mutex = Eio.Mutex.create ();
           routes = Hashtbl.create 8;
           h1_pool;
           next_h2_id = 1;
           h2_cells = 0;
           h2_requests = 0;
           redundant_cancelled = 0;
         })

let create_h2_cell_locked t =
  let cell =
    {
      id = t.next_h2_id;
      conn = Fixture_server.open_h2 t.server;
      jobs = Channel.create ~capacity:256 ();
      closed = false;
    }
  in
  t.next_h2_id <- t.next_h2_id + 1;
  t.h2_cells <- t.h2_cells + 1;
  cell

let send_reply reply value =
  Channel.send reply value |> Effect.catch (function `Closed -> Effect.unit)

let serve_h2_job mux job =
  Multiplexer.request mux ~tag:job.tag
  |> Effect.map (fun _ -> `Ok)
  |> Effect.catch (function
       | `Admission_limited -> Effect.pure `Admission_limited
       | `Closed -> Effect.pure `Closed
       | `Socket_closed -> Effect.pure `Socket_closed
       | `Stream_reset -> Effect.pure `Stream_reset
       | `Writer_full -> Effect.pure `Writer_full)
  |> Effect.bind (send_reply job.reply)

let serve_h2_cell cell =
  Multiplexer.with_connection cell.conn (fun mux ->
      Supervisor.scoped
        {
          run =
            (fun supervisor ->
              let open Supervisor.Scope in
              let next_job =
                Channel.recv cell.jobs
                |> Effect.map Option.some
                |> Effect.catch (function `Closed -> Effect.pure None)
              in
              let rec loop () =
                let* job = lift next_job in
                match job with
                | None -> pure ()
                | Some job ->
                    let* _child = start supervisor (lift (serve_h2_job mux job)) in
                    loop ()
              in
              loop ());
        })
  |> Effect.catch (function
       | `Closed | `Socket_closed -> Effect.unit
       | err -> Effect.fail err)

let start_h2_cell cell = Effect.Private.daemon (serve_h2_cell cell)

let choose_route t key =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  match Hashtbl.find_opt t.routes key with
  | Some (H2_cell cell) -> `Route (H2_cell cell)
  | Some H1_pool -> `Route H1_pool
  | Some (Pending pending) ->
      let redundant = Fixture_server.open_pending t.server in
      Pending_connection.cancel redundant;
      t.redundant_cancelled <- t.redundant_cancelled + 1;
      `Pending pending
  | None ->
      let pending = Fixture_server.open_pending t.server in
      Hashtbl.replace t.routes key (Pending pending);
      `Pending pending

let install_resolution t key pending protocol =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  match Hashtbl.find_opt t.routes key with
  | Some (H2_cell cell) -> `Route (H2_cell cell)
  | Some H1_pool -> `Route H1_pool
  | Some (Pending primary) when primary == pending -> (
      match protocol with
      | Pending_connection.H1 ->
          Hashtbl.replace t.routes key H1_pool;
          `Route H1_pool
      | H2 ->
          let cell = create_h2_cell_locked t in
          Hashtbl.replace t.routes key (H2_cell cell);
          `Start_h2 cell)
  | Some (Pending primary) -> `Pending primary
  | None -> `Pending pending

let rec route_after_pending t key pending =
  Pending_connection.resolve pending
  |> Effect.bind (fun protocol -> install_resolution t key pending protocol)
  |> Effect.bind (function
       | `Route route -> Effect.pure route
       | `Start_h2 cell -> start_h2_cell cell |> Effect.map (fun () -> H2_cell cell)
       | `Pending pending -> route_after_pending t key pending)

let request_h1 t tag =
  Pool.with_resource t.h1_pool (fun conn ->
      Effect.sync (fun () ->
          Fixture_server.record_h1_request t.server conn;
          `H1 conn.Fixture_server.id))

let request_h2 t cell tag =
  let reply = Channel.create ~capacity:1 () in
  let job = { tag; reply } in
  Effect.sync (fun () -> t.h2_requests <- t.h2_requests + 1)
  |> Effect.bind (fun () -> Channel.send cell.jobs job)
  |> Effect.bind (fun () -> Channel.recv reply)
  |> Effect.bind (function
       | `Ok -> Effect.pure (`H2 cell.id)
       | `Admission_limited -> Effect.fail `Admission_limited
       | `Closed -> Effect.fail `Closed
       | `Socket_closed -> Effect.fail `Socket_closed
       | `Stream_reset -> Effect.fail `Stream_reset
       | `Writer_full -> Effect.fail `Writer_full)

let rec dispatch_route t key tag = function
  | H1_pool -> request_h1 t tag
  | H2_cell cell -> request_h2 t cell tag
  | Pending pending ->
      route_after_pending t key pending |> Effect.bind (dispatch_route t key tag)

let request t ~host ~port ~tag =
  let key = key ~host ~port in
  choose_route t key
  |> Effect.bind (function
       | `Route route -> dispatch_route t key tag route
       | `Pending pending ->
           route_after_pending t key pending
           |> Effect.bind (dispatch_route t key tag))

let close_h2_cells t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  Hashtbl.iter
    (fun _ -> function
      | H2_cell cell when not cell.closed ->
          cell.closed <- true;
          Channel.close cell.jobs;
          Fixture_server.close_h2 t.server cell.conn
      | Pending pending -> Pending_connection.cancel pending
      | H1_pool | H2_cell _ -> ())
    t.routes

let shutdown t =
  close_h2_cells t
  |> Effect.bind (fun () ->
         Pool.shutdown t.h1_pool
         |> Effect.catch (function
              | `Pool_shutdown_timeout -> Effect.unit
              | err -> Effect.fail err))

let stats t =
  Effect.sync @@ fun () ->
  with_lock t @@ fun () ->
  {
    h1_pool = Pool.stats t.h1_pool;
    h2_cells = t.h2_cells;
    h2_requests = t.h2_requests;
    redundant_cancelled = t.redundant_cancelled;
    server = Fixture_server.stats t.server;
  }

let with_dispatcher server body =
  create server
  |> Effect.bind (fun t ->
         Effect.scoped
           (Effect.acquire_release ~acquire:(Effect.pure t) ~release:shutdown
           |> Effect.bind body))
