(* Copyright (c) 2026 Eta contributors. SPDX-License-Identifier: MIT *)

type shutdown = Server_types.shutdown =
  | Graceful of Eta.Duration.t
  | Immediate

type domain_policy = Server_types.domain_policy =
  | Single_domain
  | Recommended
  | Additional of int

type runtime_factory = Server_types.runtime_factory

module Connection_info = Server_types.Connection_info
module Config = Server_types.Config
module Stats = Server_types.Stats

type connection =
  | H1 of H1_server_connection.t
  | H2 of H2_server_connection.t

type https_connection_stats =
  | Https_h1 of H1_server_connection.stats
  | Https_h2 of H2_server_connection.stats

type t = {
  stop : unit Eio.Promise.t;
  stop_resolver : unit Eio.Promise.u;
  mutex : Eio.Mutex.t;
  mutable connections : connection list;
  mutable opened_connections : int;
  mutable closed_connections : int;
  mutable tls_handshakes : int;
  mutable tls_handshake_failures : int;
  mutable alpn_h1 : int;
  mutable alpn_h2 : int;
  mutable alpn_rejected : int;
}

let default_runtime_factory ~clock ~sw ~connection:_ () =
  Eta_eio.Runtime.create ~sw ~clock ()

let additional_domains domain_policy domain_manager =
  match (domain_policy, domain_manager) with
  | Single_domain, _ | _, None -> None
  | Recommended, Some dm ->
      Some (dm, max 0 (Domain.recommended_domain_count () - 1))
  | Additional n, Some dm -> Some (dm, max 0 n)

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
    opened_connections = 0;
    closed_connections = 0;
    tls_handshakes = 0;
    tls_handshake_failures = 0;
    alpn_h1 = 0;
    alpn_h2 = 0;
    alpn_rejected = 0;
  }

let with_lock t f =
  Eio.Mutex.lock t.mutex;
  Fun.protect ~finally:(fun () -> Eio.Mutex.unlock t.mutex) f

let register_connection t connection =
  with_lock t (fun () ->
      t.opened_connections <- t.opened_connections + 1;
      t.connections <- connection :: t.connections)

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
        t.closed_connections <- t.closed_connections + 1)

let connections t = with_lock t (fun () -> t.connections)

let record_tls_handshake t =
  with_lock t (fun () -> t.tls_handshakes <- t.tls_handshakes + 1)

let record_tls_handshake_failure t =
  with_lock t (fun () ->
      t.tls_handshake_failures <- t.tls_handshake_failures + 1)

let record_alpn_h1 t = with_lock t (fun () -> t.alpn_h1 <- t.alpn_h1 + 1)
let record_alpn_h2 t = with_lock t (fun () -> t.alpn_h2 <- t.alpn_h2 + 1)

let record_alpn_rejected t =
  with_lock t (fun () -> t.alpn_rejected <- t.alpn_rejected + 1)

let stats t =
  with_lock t (fun () ->
      {
        Stats.active_connections = List.length t.connections;
        opened_connections = t.opened_connections;
        closed_connections = t.closed_connections;
        tls_handshakes = t.tls_handshakes;
        tls_handshake_failures = t.tls_handshake_failures;
        alpn_h1 = t.alpn_h1;
        alpn_h2 = t.alpn_h2;
        alpn_rejected = t.alpn_rejected;
      })

let shutdown t policy =
  List.iter
    (function
      | H1 connection -> H1_server_connection.shutdown connection policy
      | H2 connection -> H2_server_connection.shutdown connection policy)
    (connections t);
  ignore (Eio.Promise.try_resolve t.stop_resolver ())

let run_h1_on_socket_impl ~(sw : Eio.Switch.t) ~clock ?stop
    ?(config = Config.default) ?runtime_factory ?on_connection_start
    ?on_connection_close ~(socket : _ Eio.Net.listening_socket) handler =
  ignore sw;
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop
      ~max_connections:config.max_connections
      ~on_error:(fun _exn -> ())
      (fun flow peer ->
        Eio.Switch.run @@ fun conn_sw ->
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
        H1_server_connection.run ~sw:conn_sw ~clock
          ~flow:(flow :> H1_server_connection.flow)
          ~connection:(h1_connection_info peer) ~config ~runtime_factory
          ~on_start ~on_close handler)
  in
  ()

let run_h1_on_socket ~(sw : Eio.Switch.t) ~clock ?stop
    ?(config = Config.default) ?runtime_factory ?on_connection_close
    ~(socket : _ Eio.Net.listening_socket) handler =
  let on_connection_close =
    Option.map
      (fun on_connection_close _connection stats -> on_connection_close stats)
      on_connection_close
  in
  run_h1_on_socket_impl ~sw ~clock ?stop ~config ?runtime_factory
    ?on_connection_close ~socket handler

let run_h1_impl ~sw ~net ~clock ?domain_manager
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_connection_start ?on_connection_close ~addr handler =
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:config.backlog net addr
  in
  let additional_domains = additional_domains domain_policy domain_manager in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop ?additional_domains
      ~max_connections:config.max_connections
      ~on_error:(fun _exn -> ())
      (fun flow peer ->
        Eio.Switch.run @@ fun conn_sw ->
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
        H1_server_connection.run ~sw:conn_sw ~clock
          ~flow:(flow :> H1_server_connection.flow)
          ~connection:(h1_connection_info peer) ~config ~runtime_factory
          ~on_start ~on_close handler)
  in
  ()

let run_h1 ~sw ~net ~clock ?domain_manager
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_connection_close ~addr handler =
  let on_connection_close =
    Option.map
      (fun on_connection_close _connection stats -> on_connection_close stats)
      on_connection_close
  in
  run_h1_impl ~sw ~net ~clock ?domain_manager ~domain_policy ?stop ~config
    ?runtime_factory ?on_connection_close ~addr handler

let run_h2c_on_socket_impl ~(sw : Eio.Switch.t) ~clock ?stop
    ?(config = Config.default) ?runtime_factory ?on_connection_start
    ?on_connection_close ~(socket : _ Eio.Net.listening_socket) handler =
  ignore sw;
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop
    ~max_connections:config.max_connections
    ~on_error:(fun _exn -> ())
    (fun flow peer ->
      Eio.Switch.run @@ fun conn_sw ->
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
      H2_server_connection.run_h2c ~sw:conn_sw ~clock
        ~flow:(flow :> H2_server_connection.flow)
        ~peer ~config ~runtime_factory ~on_start ~on_close handler)
  in
  ()

let run_h2c_on_socket ~(sw : Eio.Switch.t) ~clock ?stop
    ?(config = Config.default) ?runtime_factory ?on_connection_close
    ~(socket : _ Eio.Net.listening_socket) handler =
  let on_connection_close =
    Option.map (fun on_connection_close _connection stats ->
        on_connection_close stats)
      on_connection_close
  in
  run_h2c_on_socket_impl ~sw ~clock ?stop ~config ?runtime_factory
    ?on_connection_close ~socket handler

let run_h2c_impl ~sw ~net ~clock ?domain_manager
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_connection_start ?on_connection_close ~addr handler =
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:config.backlog net addr
  in
  let additional_domains = additional_domains domain_policy domain_manager in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop ?additional_domains
      ~max_connections:config.max_connections
    ~on_error:(fun _exn -> ())
    (fun flow peer ->
      Eio.Switch.run @@ fun conn_sw ->
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
      H2_server_connection.run_h2c ~sw:conn_sw ~clock
        ~flow:(flow :> H2_server_connection.flow)
        ~peer ~config ~runtime_factory ~on_start ~on_close handler)
  in
  ()

let run_h2c ~sw ~net ~clock ?domain_manager
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_connection_close ~addr handler =
  let on_connection_close =
    Option.map (fun on_connection_close _connection stats ->
        on_connection_close stats)
      on_connection_close
  in
  run_h2c_impl ~sw ~net ~clock ?domain_manager ~domain_policy ?stop ~config
    ?runtime_factory ?on_connection_close ~addr handler

let run_https_connection ~conn_sw ~clock ~config ~runtime_factory
    ?on_connection_start ?on_connection_close ?on_tls_handshake
    ?on_tls_handshake_failure ?on_alpn_h1 ?on_alpn_h2 ?on_alpn_rejected
    ~tls_config handler flow peer =
  let raw_flow =
    (flow :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] Eio.Resource.t)
  in
  let tls_flow, epoch =
    try
      let result =
        Eio.Time.with_timeout_exn clock
          (Eta.Duration.to_seconds_float config.Config.tls_handshake_timeout)
          (fun () -> Tls_eio.server_of_flow tls_config raw_flow)
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
    H1_server_connection.run ~sw:conn_sw ~clock
      ~flow:(tls_flow :> H1_server_connection.flow)
      ~connection:(https_h1_connection_info peer epoch)
      ~config ~runtime_factory
      ~on_start:(fun connection -> on_start (H1 connection))
      ~on_close:(fun stats -> on_close (Https_h1 stats))
      handler
  in
  let run_h2 () =
    Option.iter (fun f -> f ()) on_alpn_h2;
    H2_server_connection.run ~sw:conn_sw ~clock
      ~flow:(tls_flow :> H2_server_connection.flow)
      ~connection:(https_h2_connection_info peer epoch)
      ~config ~runtime_factory
      ~on_start:(fun connection -> on_start (H2 connection))
      ~on_close:(fun stats -> on_close (Https_h2 stats))
      handler
  in
  ignore
    (Alpn_server.dispatch
       ~close:(fun () ->
         Option.iter (fun f -> f ()) on_alpn_rejected;
         Eio.Flow.close tls_flow)
       ~use_h1:run_h1 ~use_h2:run_h2 epoch.alpn_protocol
      : (unit, Alpn_server.unsupported) result)

let run_https_on_socket_impl ~(sw : Eio.Switch.t) ~clock ?stop
    ?(config = Config.default) ?runtime_factory ?on_connection_start
    ?on_connection_close ?on_tls_handshake ?on_tls_handshake_failure ?on_alpn_h1
    ?on_alpn_h2 ?on_alpn_rejected ~tls_config
    ~(socket : _ Eio.Net.listening_socket) handler =
  ignore sw;
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop
      ~max_connections:config.max_connections
      ~on_error:(fun _exn -> ())
      (fun flow peer ->
        Eio.Switch.run @@ fun conn_sw ->
        run_https_connection ~conn_sw ~clock ~config ~runtime_factory
          ?on_connection_start ?on_connection_close ?on_tls_handshake
          ?on_tls_handshake_failure ?on_alpn_h1 ?on_alpn_h2 ?on_alpn_rejected
          ~tls_config handler flow peer)
  in
  ()

let run_https_on_socket ~(sw : Eio.Switch.t) ~clock ?stop
    ?(config = Config.default) ?runtime_factory ?on_connection_close
    ~tls_config ~(socket : _ Eio.Net.listening_socket) handler =
  let on_connection_close =
    Option.map
      (fun on_connection_close _connection stats -> on_connection_close stats)
      on_connection_close
  in
  run_https_on_socket_impl ~sw ~clock ?stop ~config ?runtime_factory
    ?on_connection_close ~tls_config ~socket handler

let run_https_impl ~sw ~net ~clock ?domain_manager
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_connection_start ?on_connection_close ?on_tls_handshake
    ?on_tls_handshake_failure ?on_alpn_h1 ?on_alpn_h2 ?on_alpn_rejected
    ~tls_config ~addr handler =
  let runtime_factory =
    Option.value runtime_factory ~default:(default_runtime_factory ~clock)
  in
  let socket =
    Eio.Net.listen ~sw ~reuse_addr:true ~backlog:config.backlog net addr
  in
  let additional_domains = additional_domains domain_policy domain_manager in
  let (_ : unit) =
    Eio.Net.run_server socket ?stop ?additional_domains
      ~max_connections:config.max_connections
      ~on_error:(fun _exn -> ())
      (fun flow peer ->
        Eio.Switch.run @@ fun conn_sw ->
        run_https_connection ~conn_sw ~clock ~config ~runtime_factory
          ?on_connection_start ?on_connection_close ?on_tls_handshake
          ?on_tls_handshake_failure ?on_alpn_h1 ?on_alpn_h2 ?on_alpn_rejected
          ~tls_config handler flow peer)
  in
  ()

let run_https ~sw ~net ~clock ?domain_manager
    ?(domain_policy = Recommended) ?stop ?(config = Config.default)
    ?runtime_factory ?on_connection_close ~tls_config ~addr handler =
  let on_connection_close =
    Option.map
      (fun on_connection_close _connection stats -> on_connection_close stats)
      on_connection_close
  in
  run_https_impl ~sw ~net ~clock ?domain_manager ~domain_policy ?stop ~config
    ?runtime_factory ?on_connection_close ~tls_config ~addr handler

let tracked_h1_on_close t on_connection_close connection stats =
  unregister_connection t (H1 connection);
  Option.iter (fun on_connection_close -> on_connection_close stats)
    on_connection_close

let start_h1_on_socket ~sw ~clock ?(config = Config.default) ?runtime_factory
    ?on_connection_close ~socket handler =
  let t = create () in
  Eio.Fiber.fork ~sw (fun () ->
      run_h1_on_socket_impl ~sw ~clock ~stop:t.stop ~config ?runtime_factory
        ~on_connection_start:(fun connection ->
          register_connection t (H1 connection))
        ~on_connection_close:(tracked_h1_on_close t on_connection_close)
        ~socket handler);
  t

let start_h1 ~sw ~net ~clock ?domain_manager
    ?(domain_policy = Recommended) ?(config = Config.default) ?runtime_factory
    ?on_connection_close ~addr handler =
  let t = create () in
  Eio.Fiber.fork ~sw (fun () ->
      run_h1_impl ~sw ~net ~clock ?domain_manager ~domain_policy ~stop:t.stop
        ~config ?runtime_factory
        ~on_connection_start:(fun connection ->
          register_connection t (H1 connection))
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

let start_h2c_on_socket ~sw ~clock ?(config = Config.default) ?runtime_factory
    ?on_connection_close ~socket handler =
  let t = create () in
  Eio.Fiber.fork ~sw (fun () ->
      run_h2c_on_socket_impl ~sw ~clock ~stop:t.stop ~config ?runtime_factory
        ~on_connection_start:(fun connection ->
          register_connection t (H2 connection))
        ~on_connection_close:(tracked_h2_on_close t on_connection_close)
        ~socket handler);
  t

let start_h2c ~sw ~net ~clock ?domain_manager
    ?(domain_policy = Recommended) ?(config = Config.default) ?runtime_factory
    ?on_connection_close ~addr handler =
  let t = create () in
  Eio.Fiber.fork ~sw (fun () ->
      run_h2c_impl ~sw ~net ~clock ?domain_manager ~domain_policy ~stop:t.stop
        ~config ?runtime_factory
        ~on_connection_start:(fun connection ->
          register_connection t (H2 connection))
        ~on_connection_close:(tracked_h2_on_close t on_connection_close)
        ~addr handler);
  t

let start_https_on_socket ~sw ~clock ?(config = Config.default) ?runtime_factory
    ?on_connection_close ~tls_config ~socket handler =
  let t = create () in
  Eio.Fiber.fork ~sw (fun () ->
      run_https_on_socket_impl ~sw ~clock ~stop:t.stop ~config ?runtime_factory
        ~on_connection_start:(fun connection -> register_connection t connection)
        ~on_connection_close:(tracked_https_on_close t on_connection_close)
        ~on_tls_handshake:(fun () -> record_tls_handshake t)
        ~on_tls_handshake_failure:(fun () -> record_tls_handshake_failure t)
        ~on_alpn_h1:(fun () -> record_alpn_h1 t)
        ~on_alpn_h2:(fun () -> record_alpn_h2 t)
        ~on_alpn_rejected:(fun () -> record_alpn_rejected t)
        ~tls_config ~socket handler);
  t

let start_https ~sw ~net ~clock ?domain_manager
    ?(domain_policy = Recommended) ?(config = Config.default) ?runtime_factory
    ?on_connection_close ~tls_config ~addr handler =
  let t = create () in
  Eio.Fiber.fork ~sw (fun () ->
      run_https_impl ~sw ~net ~clock ?domain_manager ~domain_policy ~stop:t.stop
        ~config ?runtime_factory
        ~on_connection_start:(fun connection -> register_connection t connection)
        ~on_connection_close:(tracked_https_on_close t on_connection_close)
        ~on_tls_handshake:(fun () -> record_tls_handshake t)
        ~on_tls_handshake_failure:(fun () -> record_tls_handshake_failure t)
        ~on_alpn_h1:(fun () -> record_alpn_h1 t)
        ~on_alpn_h2:(fun () -> record_alpn_h2 t)
        ~on_alpn_rejected:(fun () -> record_alpn_rejected t)
        ~tls_config ~addr handler);
  t
