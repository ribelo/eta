(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type shutdown = Server_types.shutdown =
  | Graceful of Eta.Duration.t
  | Immediate

type domain_policy = Server_types.domain_policy =
  | Single_domain
  | Recommended
  | Additional of int

type runtime_factory = Server_types.runtime_factory

type time = Server_types.time = {
  now_ms : unit -> int64;
  sleep : Eta.Duration.t -> unit;
  with_timeout : 'a. Eta.Duration.t -> (unit -> 'a) -> 'a;
}

module Connection_info = Server_types.Connection_info
module Config = Server_types.Config
module Stats = Server_types.Stats

let live_time = Server_types.live_time

type connection =
  | H1 of H1_server_connection.t
  | H2 of H2_server_connection.t

type raw_flow = [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t

let set_tcp_nodelay flow =
  match Eio_unix.Resource.fd_opt flow with
  | None -> ()
  | Some fd ->
      Eio_unix.Fd.use fd
        (fun unix_fd -> Unix.setsockopt unix_fd Unix.TCP_NODELAY true)
        ~if_closed:(fun () -> ())

let accepted_flow ~peer flow =
  let flow = (flow :> raw_flow) in
  (match peer with `Tcp _ -> set_tcp_nodelay flow | `Unix _ -> ());
  flow

type pending_tls = {
  id : int;
  flow : raw_flow;
}

type https_connection_stats =
  | Https_h1 of H1_server_connection.stats
  | Https_h2 of H2_server_connection.stats

type t = {
  stop : unit Eio.Promise.t;
  stop_resolver : unit Eio.Promise.u;
  mutex : Eio.Mutex.t;
  mutable connections : connection list;
  mutable pending_tls : pending_tls list;
  mutable close_listeners : (unit -> unit) list;
  mutable shutdown_policy : shutdown option;
  stats : Server_stats.Listener.t;
}

let default_runtime_factory ~clock ~sw ~connection:_ () =
  Eta_eio.Runtime.create ~sw ~clock ()

let additional_domains domain_policy domain_manager =
  match (domain_policy, domain_manager) with
  | Single_domain, _ | _, None -> None
  | Recommended, Some dm ->
      Some (dm, max 0 (Domain.recommended_domain_count () - 1))
  | Additional n, Some dm -> Some (dm, n)

let validate_domain_policy = function
  | Additional n when n < 0 ->
      invalid_arg "Eta_http_eio.Server.Additional must be >= 0"
  | Single_domain | Recommended | Additional _ -> ()

let peer_of_sockaddr = function
  | `Tcp (address, port) ->
      {
        Eta_http.Server.Request.address =
          Some (Format.asprintf "%a" Eio.Net.Ipaddr.pp address);
        port = Some port;
      }
  | `Unix path -> { Eta_http.Server.Request.address = Some path; port = None }

let h1_connection_id =
  let next = Atomic.make 0 in
  fun () ->
    let id = Atomic.fetch_and_add next 1 + 1 in
    "h1-" ^ string_of_int id

let pending_tls_id =
  let next = Atomic.make 0 in
  fun () -> Atomic.fetch_and_add next 1 + 1

let h1_connection_info peer =
  {
    Connection_info.id = h1_connection_id ();
    peer = peer_of_sockaddr peer;
    protocol = Eta_http.Server.Error.H1;
    tls = false;
    alpn_protocol = None;
  }

let h2_tls_connection_id =
  let next = Atomic.make 0 in
  fun () ->
    let id = Atomic.fetch_and_add next 1 + 1 in
    "h2-tls-" ^ string_of_int id

let https_h1_connection_info peer (epoch : Tls_eio.epoch) =
  {
    Connection_info.id = h1_connection_id ();
    peer = peer_of_sockaddr peer;
    protocol = Eta_http.Server.Error.H1;
    tls = true;
    alpn_protocol = epoch.alpn_protocol;
  }

let https_h2_connection_info peer (epoch : Tls_eio.epoch) =
  {
    Connection_info.id = h2_tls_connection_id ();
    peer = peer_of_sockaddr peer;
    protocol = Eta_http.Server.Error.H2;
    tls = true;
    alpn_protocol = epoch.alpn_protocol;
  }

let create () =
  let stop, stop_resolver = Eio.Promise.create () in
  {
    stop;
    stop_resolver;
    mutex = Eio.Mutex.create ();
    connections = [];
    pending_tls = [];
    close_listeners = [];
    shutdown_policy = None;
    stats = Server_stats.Listener.create ();
  }

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let shutdown_connection policy = function
  | H1 connection -> H1_server_connection.shutdown connection policy
  | H2 connection -> H2_server_connection.shutdown connection policy

let register_connection t connection =
  let shutdown_policy =
    with_lock t (fun () ->
        Server_stats.Listener.opened_connection t.stats;
        t.connections <- connection :: t.connections;
        t.shutdown_policy)
  in
  Option.iter (fun policy -> shutdown_connection policy connection)
    shutdown_policy

let register_transitioned_connection t connection =
  let shutdown_policy =
    with_lock t (fun () ->
        t.connections <- connection :: t.connections;
        t.shutdown_policy)
  in
  Option.iter (fun policy -> shutdown_connection policy connection)
    shutdown_policy

let register_pending_tls t flow =
  let pending = { id = pending_tls_id (); flow } in
  let shutdown_requested =
    with_lock t (fun () ->
        Server_stats.Listener.opened_connection t.stats;
        t.pending_tls <- pending :: t.pending_tls;
        Option.is_some t.shutdown_policy)
  in
  if shutdown_requested then (
    (try Eio.Flow.shutdown flow `All with _ -> ());
    try Eio.Flow.close flow with _ -> ());
  pending

let unregister_pending_tls ?(closed = true) t pending =
  with_lock t (fun () ->
      let before = List.length t.pending_tls in
      t.pending_tls <-
        List.filter
          (fun current -> current.id <> pending.id)
          t.pending_tls;
      if closed && List.length t.pending_tls <> before then
        Server_stats.Listener.closed_connection t.stats)

let same_connection left right =
  match (left, right) with
  | H1 left, H1 right -> left == right
  | H2 left, H2 right -> left == right
  | H1 _, H2 _ | H2 _, H1 _ -> false

let unregister_connection t connection =
  with_lock t (fun () ->
      let before = List.length t.connections in
      t.connections <-
        List.filter
          (fun current -> not (same_connection current connection))
          t.connections;
      if List.length t.connections <> before then
        Server_stats.Listener.closed_connection t.stats)

let connections t = with_lock t (fun () -> t.connections)
let pending_tls t = with_lock t (fun () -> t.pending_tls)

let register_listener t socket =
  let close () = try Eio.Resource.close socket with _ -> () in
  let shutdown_requested =
    with_lock t (fun () ->
        match t.shutdown_policy with
        | None ->
            t.close_listeners <- close :: t.close_listeners;
            false
        | Some _ -> true)
  in
  if shutdown_requested then close ()

let close_listeners t =
  let listeners =
    with_lock t (fun () ->
        let listeners = t.close_listeners in
        t.close_listeners <- [];
        listeners)
  in
  List.iter (fun close -> close ()) listeners

let record_tls_handshake t =
  with_lock t (fun () -> Server_stats.Listener.tls_handshake t.stats)

let record_tls_handshake_failure t =
  with_lock t (fun () -> Server_stats.Listener.tls_handshake_failure t.stats)

let record_alpn_h1 t =
  with_lock t (fun () -> Server_stats.Listener.alpn_h1 t.stats)

let record_alpn_h2 t =
  with_lock t (fun () -> Server_stats.Listener.alpn_h2 t.stats)

let record_alpn_rejected t =
  with_lock t (fun () -> Server_stats.Listener.alpn_rejected t.stats)

let record_listener_error t =
  with_lock t (fun () -> Server_stats.Listener.listener_error t.stats)

let listener_error_callback on_error exn =
  Option.iter (fun on_error -> on_error exn) on_error

let tracked_listener_error t on_error exn =
  record_listener_error t;
  listener_error_callback on_error exn

let stats t =
  with_lock t (fun () ->
      Server_stats.Listener.snapshot t.stats
        ~active_connections:
          (List.length t.connections + List.length t.pending_tls))

let close_pending_tls t =
  List.iter
    (fun pending ->
      (try Eio.Flow.shutdown pending.flow `All with _ -> ());
      try Eio.Flow.close pending.flow with _ -> ())
    (pending_tls t)

let with_pending_tls ?on_tls_pending_start ?on_tls_pending_ready
    ?on_tls_pending_close flow f =
  let raw_flow = (flow :> raw_flow) in
  let pending = Option.map (fun start -> start raw_flow) on_tls_pending_start in
  let pending_active = ref pending in
  let finish_pending ~closed =
    match !pending_active with
    | None -> ()
    | Some pending ->
        pending_active := None;
        if closed then
          Option.iter (fun close -> close pending) on_tls_pending_close
        else Option.iter (fun ready -> ready pending) on_tls_pending_ready
  in
  Fun.protect
    ~finally:(fun () -> finish_pending ~closed:true)
    (fun () -> f (fun () -> finish_pending ~closed:false))

let shutdown t policy =
  ignore (Eio.Promise.try_resolve t.stop_resolver ());
  with_lock t (fun () -> t.shutdown_policy <- Some policy);
  close_listeners t;
  close_pending_tls t;
  List.iter (shutdown_connection policy) (connections t)

let run_h1_on_socket_impl ~(sw : Eio.Switch.t) ~clock ?time ?stop
    ?(config = Config.default) ?runtime_factory ?on_error ?on_connection_start
    ?on_connection_close ~(socket : _ Eio.Net.listening_socket) handler =
  Config.validate config;
  ignore sw;
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop
      ~max_connections:config.max_connections
      ~on_error:(listener_error_callback on_error)
      (fun flow peer ->
        Eio.Switch.run @@ fun conn_sw ->
        let flow = accepted_flow ~peer flow in
        let connection = ref None in
        let on_start current =
          connection := Some current;
          Option.iter (fun on_connection_start -> on_connection_start current)
            on_connection_start
        in
        let on_close stats =
          match !connection with
          | None -> ()
          | Some current ->
              Option.iter
                (fun on_connection_close -> on_connection_close current stats)
                on_connection_close
        in
        H1_server_connection.run ~sw:conn_sw ~clock ?time
          ~flow:(flow :> H1_server_connection.flow)
          ~connection:(h1_connection_info peer) ~config ~runtime_factory
          ~on_start ~on_close handler)
  in
  ()

let run_h1_on_socket ~(sw : Eio.Switch.t) ~clock ?time ?stop
    ?(config = Config.default) ?runtime_factory ?on_error ?on_connection_close
    ~(socket : _ Eio.Net.listening_socket) handler =
  let on_connection_close =
    Option.map
      (fun on_connection_close _connection stats -> on_connection_close stats)
      on_connection_close
  in
  run_h1_on_socket_impl ~sw ~clock ?time ?stop ~config ?runtime_factory ?on_error
    ?on_connection_close ~socket handler

let run_h1_impl ~sw ~net ~clock ?time ?domain_manager ?on_listener_start
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_error ?on_connection_start ?on_connection_close ~addr
    handler =
  Config.validate config;
  validate_domain_policy domain_policy;
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:config.backlog net addr
  in
  Option.iter (fun on_listener_start -> on_listener_start socket)
    on_listener_start;
  let additional_domains = additional_domains domain_policy domain_manager in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop ?additional_domains
      ~max_connections:config.max_connections
      ~on_error:(listener_error_callback on_error)
      (fun flow peer ->
        Eio.Switch.run @@ fun conn_sw ->
        let flow = accepted_flow ~peer flow in
        let connection = ref None in
        let on_start current =
          connection := Some current;
          Option.iter (fun on_connection_start -> on_connection_start current)
            on_connection_start
        in
        let on_close stats =
          match !connection with
          | None -> ()
          | Some current ->
              Option.iter
                (fun on_connection_close -> on_connection_close current stats)
                on_connection_close
        in
        H1_server_connection.run ~sw:conn_sw ~clock ?time
          ~flow:(flow :> H1_server_connection.flow)
          ~connection:(h1_connection_info peer) ~config ~runtime_factory
          ~on_start ~on_close handler)
  in
  ()

let run_h1 ~sw ~net ~clock ?time ?domain_manager
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_error ?on_connection_close ~addr handler =
  let on_connection_close =
    Option.map
      (fun on_connection_close _connection stats -> on_connection_close stats)
      on_connection_close
  in
  run_h1_impl ~sw ~net ~clock ?time ?domain_manager ~domain_policy ?stop ~config
    ?runtime_factory ?on_error ?on_connection_close ~addr handler

let run_h2c_on_socket_impl ~(sw : Eio.Switch.t) ~clock ?time ?stop
    ?(config = Config.default) ?runtime_factory ?on_error ?on_connection_start
    ?on_connection_close ~(socket : _ Eio.Net.listening_socket) handler =
  Config.validate config;
  ignore sw;
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop
      ~max_connections:config.max_connections
      ~on_error:(listener_error_callback on_error)
      (fun flow peer ->
        Eio.Switch.run @@ fun conn_sw ->
        let flow = accepted_flow ~peer flow in
        let connection = ref None in
        let on_start current =
          connection := Some current;
          Option.iter (fun on_connection_start -> on_connection_start current)
            on_connection_start
        in
        let on_close stats =
          match !connection with
          | None -> ()
          | Some current ->
              Option.iter
                (fun on_connection_close -> on_connection_close current stats)
                on_connection_close
        in
        H2_server_connection.run_h2c ~sw:conn_sw ~clock ?time
          ~flow:(flow :> H2_server_connection.flow)
          ~peer ~config ~runtime_factory ~on_start ~on_close handler)
  in
  ()

let run_h2c_on_socket ~(sw : Eio.Switch.t) ~clock ?time ?stop
    ?(config = Config.default) ?runtime_factory ?on_error ?on_connection_close
    ~(socket : _ Eio.Net.listening_socket) handler =
  let on_connection_close =
    Option.map (fun on_connection_close _connection stats ->
        on_connection_close stats)
      on_connection_close
  in
  run_h2c_on_socket_impl ~sw ~clock ?time ?stop ~config ?runtime_factory
    ?on_error
    ?on_connection_close ~socket handler

let run_h2c_impl ~sw ~net ~clock ?time ?domain_manager ?on_listener_start
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_error ?on_connection_start ?on_connection_close ~addr
    handler =
  Config.validate config;
  validate_domain_policy domain_policy;
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:config.backlog net addr
  in
  Option.iter (fun on_listener_start -> on_listener_start socket)
    on_listener_start;
  let additional_domains = additional_domains domain_policy domain_manager in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop ?additional_domains
      ~max_connections:config.max_connections
      ~on_error:(listener_error_callback on_error)
      (fun flow peer ->
        Eio.Switch.run @@ fun conn_sw ->
        let flow = accepted_flow ~peer flow in
        let connection = ref None in
        let on_start current =
          connection := Some current;
          Option.iter (fun on_connection_start -> on_connection_start current)
            on_connection_start
        in
        let on_close stats =
          match !connection with
          | None -> ()
          | Some current ->
              Option.iter
                (fun on_connection_close -> on_connection_close current stats)
                on_connection_close
        in
        H2_server_connection.run_h2c ~sw:conn_sw ~clock ?time
          ~flow:(flow :> H2_server_connection.flow)
          ~peer ~config ~runtime_factory ~on_start ~on_close handler)
  in
  ()

let run_h2c ~sw ~net ~clock ?time ?domain_manager
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_error ?on_connection_close ~addr handler =
  let on_connection_close =
    Option.map (fun on_connection_close _connection stats ->
        on_connection_close stats)
      on_connection_close
  in
  run_h2c_impl ~sw ~net ~clock ?time ?domain_manager ~domain_policy ?stop
    ~config
    ?runtime_factory ?on_error ?on_connection_close ~addr handler

let run_https_connection ~conn_sw ~clock ?time ~config ~runtime_factory
    ?on_connection_start ?on_connection_close ?on_tls_handshake
    ?on_tls_handshake_failure ?on_alpn_h1 ?on_alpn_h2 ?on_alpn_rejected
    ~tls_context ~enabled_protocols handler flow peer =
  let raw_flow =
    (flow :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let time = Option.value time ~default:(live_time clock) in
  let tls_flow, epoch =
    try
      let result =
        time.with_timeout config.Config.tls_handshake_timeout (fun () ->
            Tls_eio.server_of_flow_with_context tls_context raw_flow)
      in
      Option.iter (fun f -> f ()) on_tls_handshake;
      result
    with
    | Eio.Time.Timeout as exn ->
        Option.iter (fun f -> f ()) on_tls_handshake_failure;
        (try Eio.Flow.close raw_flow with _ -> ());
        raise exn
    | exn ->
        Option.iter (fun f -> f ()) on_tls_handshake_failure;
        (try Eio.Flow.close raw_flow with _ -> ());
        raise exn
  in
  let current = ref None in
  let on_start connection =
    current := Some connection;
    Option.iter
      (fun on_connection_start -> on_connection_start connection)
      on_connection_start
  in
  let on_close stats =
    match !current with
    | None -> ()
    | Some connection ->
        Option.iter
          (fun on_connection_close -> on_connection_close connection stats)
          on_connection_close
  in
  let run_h1 () =
    Option.iter (fun f -> f ()) on_alpn_h1;
    H1_server_connection.run ~sw:conn_sw ~clock ~time
      ~flow:(tls_flow :> H1_server_connection.flow)
      ~connection:(https_h1_connection_info peer epoch)
      ~config ~runtime_factory
      ~on_start:(fun connection -> on_start (H1 connection))
      ~on_close:(fun stats -> on_close (Https_h1 stats))
      handler
  in
  let run_h2 () =
    Option.iter (fun f -> f ()) on_alpn_h2;
    H2_server_connection.run ~sw:conn_sw ~clock ~time
      ~flow:(tls_flow :> H2_server_connection.flow)
      ~connection:(https_h2_connection_info peer epoch)
      ~config ~runtime_factory
      ~on_start:(fun connection -> on_start (H2 connection))
      ~on_close:(fun stats -> on_close (Https_h2 stats))
      handler
  in
  ignore
    (Alpn_server.dispatch
       ~enabled_protocols
       ~close:(fun () ->
         Option.iter (fun f -> f ()) on_alpn_rejected;
         Eio.Flow.close tls_flow)
       ~use_h1:run_h1 ~use_h2:run_h2 epoch.alpn_protocol
      : (unit, Alpn_server.unsupported) result)

let run_https_on_socket_impl ~(sw : Eio.Switch.t) ~clock ?time ?stop
    ?(config = Config.default) ?runtime_factory ?on_error ?on_connection_start
    ?on_connection_close ?on_tls_handshake ?on_tls_handshake_failure ?on_alpn_h1
    ?on_alpn_h2 ?on_alpn_rejected ?on_tls_pending_start
    ?on_tls_pending_ready ?on_tls_pending_close ~tls_context ~enabled_protocols
    ~(socket : _ Eio.Net.listening_socket) handler =
  Config.validate config;
  ignore sw;
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop
      ~max_connections:config.max_connections
      ~on_error:(listener_error_callback on_error)
      (fun flow peer ->
        Eio.Switch.run @@ fun conn_sw ->
        let flow = accepted_flow ~peer flow in
        with_pending_tls ?on_tls_pending_start ?on_tls_pending_ready
          ?on_tls_pending_close flow
          (fun finish_pending ->
            let on_connection_start connection =
              Option.iter
                (fun on_connection_start -> on_connection_start connection)
                on_connection_start;
              finish_pending ()
            in
            run_https_connection ~conn_sw ~clock ?time ~config ~runtime_factory
              ~on_connection_start ?on_connection_close ?on_tls_handshake
              ?on_tls_handshake_failure ?on_alpn_h1 ?on_alpn_h2 ?on_alpn_rejected
              ~tls_context ~enabled_protocols handler flow peer))
  in
  ()

let run_https_on_socket ~(sw : Eio.Switch.t) ~clock ?time ?stop
    ?(config = Config.default) ?runtime_factory ?on_error ?on_connection_close
    ~tls_config ~(socket : _ Eio.Net.listening_socket) handler =
  Config.validate config;
  let tls_context = Tls_eio.server_context tls_config in
  let enabled_protocols =
    Eta_http.Transport.Dispatch.enabled_protocols_of_alpn_protocols
      (Eta_http.Tls.Config.server_alpn_protocols tls_config)
  in
  let on_connection_close =
    Option.map
      (fun on_connection_close _connection stats -> on_connection_close stats)
      on_connection_close
  in
  run_https_on_socket_impl ~sw ~clock ?time ?stop ~config ?runtime_factory
    ?on_error ?on_connection_close ~tls_context ~enabled_protocols ~socket
    handler

let run_https_impl ~sw ~net ~clock ?time ?domain_manager ?on_listener_start
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_error ?on_connection_start ?on_connection_close
    ?on_tls_handshake ?on_tls_handshake_failure ?on_alpn_h1 ?on_alpn_h2
    ?on_alpn_rejected ?on_tls_pending_start ?on_tls_pending_ready
    ?on_tls_pending_close ~tls_context ~enabled_protocols ~addr handler =
  Config.validate config;
  validate_domain_policy domain_policy;
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:config.backlog net addr
  in
  Option.iter (fun on_listener_start -> on_listener_start socket)
    on_listener_start;
  let additional_domains = additional_domains domain_policy domain_manager in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop ?additional_domains
      ~max_connections:config.max_connections
      ~on_error:(listener_error_callback on_error)
      (fun flow peer ->
        Eio.Switch.run @@ fun conn_sw ->
        let flow = accepted_flow ~peer flow in
        with_pending_tls ?on_tls_pending_start ?on_tls_pending_ready
          ?on_tls_pending_close flow
          (fun finish_pending ->
            let on_connection_start connection =
              Option.iter
                (fun on_connection_start -> on_connection_start connection)
                on_connection_start;
              finish_pending ()
            in
            run_https_connection ~conn_sw ~clock ?time ~config ~runtime_factory
              ~on_connection_start ?on_connection_close ?on_tls_handshake
              ?on_tls_handshake_failure ?on_alpn_h1 ?on_alpn_h2 ?on_alpn_rejected
              ~tls_context ~enabled_protocols handler flow peer))
  in
  ()

let run_https ~sw ~net ~clock ?time ?domain_manager
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_error ?on_connection_close ~tls_config ~addr handler =
  Config.validate config;
  validate_domain_policy domain_policy;
  let tls_context = Tls_eio.server_context tls_config in
  let enabled_protocols =
    Eta_http.Transport.Dispatch.enabled_protocols_of_alpn_protocols
      (Eta_http.Tls.Config.server_alpn_protocols tls_config)
  in
  let on_connection_close =
    Option.map
      (fun on_connection_close _connection stats -> on_connection_close stats)
      on_connection_close
  in
  run_https_impl ~sw ~net ~clock ?time ?domain_manager ~domain_policy ?stop
    ~config ?runtime_factory ?on_error ?on_connection_close ~tls_context ~addr
    ~enabled_protocols handler

let tracked_h1_on_close t on_connection_close connection stats =
  unregister_connection t (H1 connection);
  Option.iter (fun on_connection_close -> on_connection_close stats)
    on_connection_close

let start_h1_on_socket ~sw ~clock ?time ?(config = Config.default) ?runtime_factory
    ?on_error ?on_connection_close ~socket handler =
  Config.validate config;
  let t = create () in
  register_listener t socket;
  Eio.Fiber.fork ~sw (fun () ->
      run_h1_on_socket_impl ~sw ~clock ?time ~stop:t.stop ~config ?runtime_factory
        ~on_error:(tracked_listener_error t on_error)
        ~on_connection_start:(fun connection ->
          register_connection t (H1 connection))
        ~on_connection_close:(tracked_h1_on_close t on_connection_close)
        ~socket handler);
  t

let start_h1 ~sw ~net ~clock ?time ?domain_manager
    ?(domain_policy = Recommended) ?(config = Config.default) ?runtime_factory
    ?on_error ?on_connection_close ~addr handler =
  Config.validate config;
  validate_domain_policy domain_policy;
  let t = create () in
  Eio.Fiber.fork ~sw (fun () ->
      run_h1_impl ~sw ~net ~clock ?time ?domain_manager ~domain_policy
        ~stop:t.stop ~config ?runtime_factory
        ~on_error:(tracked_listener_error t on_error)
        ~on_listener_start:(fun socket -> register_listener t socket)
        ~on_connection_start:(fun connection -> register_connection t (H1 connection))
        ~on_connection_close:(tracked_h1_on_close t on_connection_close)
        ~addr handler);
  t

let tracked_h2_on_close t on_connection_close connection stats =
  unregister_connection t (H2 connection);
  Option.iter (fun on_connection_close -> on_connection_close stats)
    on_connection_close

let tracked_https_on_close t on_connection_close connection stats =
  unregister_connection t connection;
  Option.iter (fun on_connection_close -> on_connection_close stats)
    on_connection_close

let start_h2c_on_socket ~sw ~clock ?time ?(config = Config.default)
    ?runtime_factory
    ?on_error ?on_connection_close ~socket handler =
  Config.validate config;
  let t = create () in
  register_listener t socket;
  Eio.Fiber.fork ~sw (fun () ->
      run_h2c_on_socket_impl ~sw ~clock ?time ~stop:t.stop ~config ?runtime_factory
        ~on_error:(tracked_listener_error t on_error)
        ~on_connection_start:(fun connection ->
          register_connection t (H2 connection))
        ~on_connection_close:(tracked_h2_on_close t on_connection_close)
        ~socket handler);
  t

let start_h2c ~sw ~net ~clock ?time ?domain_manager
    ?(domain_policy = Recommended) ?(config = Config.default) ?runtime_factory
    ?on_error ?on_connection_close ~addr handler =
  Config.validate config;
  validate_domain_policy domain_policy;
  let t = create () in
  Eio.Fiber.fork ~sw (fun () ->
      run_h2c_impl ~sw ~net ~clock ?time ?domain_manager ~domain_policy
        ~stop:t.stop ~config ?runtime_factory
        ~on_error:(tracked_listener_error t on_error)
        ~on_listener_start:(fun socket -> register_listener t socket)
        ~on_connection_start:(fun connection -> register_connection t (H2 connection))
        ~on_connection_close:(tracked_h2_on_close t on_connection_close)
        ~addr handler);
  t

let start_https_on_socket ~sw ~clock ?time ?(config = Config.default)
    ?runtime_factory ?on_error ?on_connection_close ~tls_config ~socket handler =
  Config.validate config;
  let tls_context = Tls_eio.server_context tls_config in
  let enabled_protocols =
    Eta_http.Transport.Dispatch.enabled_protocols_of_alpn_protocols
      (Eta_http.Tls.Config.server_alpn_protocols tls_config)
  in
  let t = create () in
  register_listener t socket;
  Eio.Fiber.fork ~sw (fun () ->
      run_https_on_socket_impl ~sw ~clock ?time ~stop:t.stop ~config
        ?runtime_factory
        ~on_error:(tracked_listener_error t on_error)
        ~on_connection_start:(fun connection ->
          register_transitioned_connection t connection)
        ~on_connection_close:(tracked_https_on_close t on_connection_close)
        ~on_tls_handshake:(fun () -> record_tls_handshake t)
        ~on_tls_handshake_failure:(fun () -> record_tls_handshake_failure t)
        ~on_alpn_h1:(fun () -> record_alpn_h1 t)
        ~on_alpn_h2:(fun () -> record_alpn_h2 t)
        ~on_alpn_rejected:(fun () -> record_alpn_rejected t)
        ~on_tls_pending_start:(fun flow -> register_pending_tls t flow)
        ~on_tls_pending_ready:(fun pending ->
          unregister_pending_tls ~closed:false t pending)
        ~on_tls_pending_close:(fun pending -> unregister_pending_tls t pending)
        ~tls_context ~enabled_protocols ~socket handler);
  t

let start_https ~sw ~net ~clock ?time ?domain_manager
    ?(domain_policy = Recommended) ?(config = Config.default) ?runtime_factory
    ?on_error ?on_connection_close ~tls_config ~addr handler =
  Config.validate config;
  validate_domain_policy domain_policy;
  let tls_context = Tls_eio.server_context tls_config in
  let enabled_protocols =
    Eta_http.Transport.Dispatch.enabled_protocols_of_alpn_protocols
      (Eta_http.Tls.Config.server_alpn_protocols tls_config)
  in
  let t = create () in
  Eio.Fiber.fork ~sw (fun () ->
      run_https_impl ~sw ~net ~clock ?time ?domain_manager ~domain_policy
        ~stop:t.stop ~config ?runtime_factory
        ~on_error:(tracked_listener_error t on_error)
        ~on_listener_start:(fun socket -> register_listener t socket)
        ~on_connection_start:(fun connection ->
          register_transitioned_connection t connection)
        ~on_connection_close:(tracked_https_on_close t on_connection_close)
        ~on_tls_handshake:(fun () -> record_tls_handshake t)
        ~on_tls_handshake_failure:(fun () -> record_tls_handshake_failure t)
        ~on_alpn_h1:(fun () -> record_alpn_h1 t)
        ~on_alpn_h2:(fun () -> record_alpn_h2 t)
        ~on_alpn_rejected:(fun () -> record_alpn_rejected t)
        ~on_tls_pending_start:(fun flow -> register_pending_tls t flow)
        ~on_tls_pending_ready:(fun pending ->
          unregister_pending_tls ~closed:false t pending)
        ~on_tls_pending_close:(fun pending -> unregister_pending_tls t pending)
        ~tls_context ~enabled_protocols ~addr handler);
  t
